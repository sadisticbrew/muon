// go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

// Scratch value stored in pending_mmaps on sys_enter_mmap so sys_exit_mmap can
// recover both the requesting pid and the requested size (neither is in the exit ctx).
struct mmap_temp{
    __u32 pid;
    __u64 size;
};

// Scratch value stored in pending_brks so sys_exit_brk can compute the delta.
// Only the old brk is needed; the new one comes from ctx->ret on exit.
struct brk_temp {
    __u64 old;
};

struct alloc_event {
    __u64 addr;
    __u64 size;
    __u16 flag;  // one of ALLOC / FREE / FREE_NO_HISTORY
};

// Composite key for active_allocs: addr alone isn't unique across processes.
struct alloc_key {
    __u64 addr;
    __u32 pid;
};

// Single event type shared across all probes. The union avoids over-allocating
// for small events (alloc_data) vs large ones (fname). Userspace dispatches on `type`.
struct event {
    __u32 pid;
    __u32 type;   // 0=exec, 1=openat, 2=exit, 3=connect, 4=mmap/munmap, 5=brk
    __u64 timestamp;
    char comm[16];
    union {
        char fname[256];               // for exec / openat
        unsigned char raw_addr[128];   // raw sockaddr bytes for connect (decoded in userspace)
        struct alloc_event alloc_data; // for mmap, munmap, brk
    } data;
};

// ---- BPF Maps ----

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 14);
    __type(key, __u32);    // pid
    __type(value, __u64);  // current heap size in bytes
} heap_totals SEC(".maps");

// Lock-free, variable-length output channel to userspace. 64 MB chosen to
// absorb bursts without dropping under moderate allocation churn.
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 26);
} events SEC(".maps");

// Set of PIDs being monitored. Userspace inserts the root PID at attach time;
// fork/exec probes propagate entries to child PIDs automatically.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 14);
    __type(key, __u32);
    __type(value, __u32);
} tracked_pids SEC(".maps");

// Per-CPU counter for ringbuf reservation failures. Per-CPU avoids atomic ops
// on the hot path; userspace should sum across CPUs when reading.
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} drop_counter SEC(".maps");

// Keyed by pid_tgid (unique per in-flight syscall) to correlate enter↔exit for mmap.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 20);
    __type(key, __u64);
    __type(value, struct mmap_temp);
} pending_mmaps SEC(".maps");

// Same correlation pattern for brk.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 20);
    __type(key, __u64);
    __type(value, struct brk_temp);
} pending_brks SEC(".maps");

// Ground truth of live mmap'd regions per process. Lets munmap correctly
// attribute freed bytes and detect partial unmaps.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 20);
    __type(key, struct alloc_key);
    __type(value, __u64);
} active_allocs SEC(".maps");

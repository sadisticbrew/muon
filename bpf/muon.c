// go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

#include "maps.c"
#include "memory.h"

char __license[] SEC("license") = "Dual MIT/GPL";

// Injected at load time from userspace via BPF skeleton. Not used for filtering
// directly here, but kept for potential future use.
volatile const __u32 target_pid;

// Flags carried in alloc_event.flag to let userspace know the nature of each event
// without needing to diff maps on the userspace side.
#define ALLOC           0
#define FREE            1
#define FREE_NO_HISTORY 2  // munmap on an addr we never saw mmap'd (e.g. pre-attach allocations)

// ---------- Helper funcs --------------

// Centralises drop-counting so callers don't repeat the increment logic.
// Returns 1 (treat as empty/unusable) both when the pointer is NULL and
// when the drop_counter lookup fails — the latter shouldn't happen but keeps
// the verifier happy.
int is_event_empty(struct event *e) {
    if (!e) {
        __u32 key = 0;
        __u64 *count = bpf_map_lookup_elem(&drop_counter, &key);
        if (count) {
            *count += 1;
        }
        return 1;}
    return 0;
}

// ---------------------------------------

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *ctx) {

    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;
    e->type = 1;
    e->timestamp = bpf_ktime_get_ns();
    e->pid =pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    // args[1] is the userspace pointer to the path string (dirfd is args[0]).
    char *fname = (char *)ctx->args[1];
    int res = bpf_probe_read_user_str(&e->data.fname, sizeof(e->data.fname), fname);
    if (res < 0) {
        bpf_ringbuf_discard(e, 0);
        return 0;
    }

    bpf_ringbuf_submit(e, 0);

    return 0;
}

SEC("tracepoint/syscalls/sys_enter_connect")
int trace_connect(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;
    e->type = 3;
    e->timestamp = bpf_ktime_get_ns();
    e->pid = pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    // args[1] is a userspace pointer to a sockaddr struct. We read it as raw
    // bytes and let userspace interpret the sa_family + address fields, since
    // the actual struct variant (sockaddr_in, sockaddr_in6, sockaddr_un, ...)
    // isn't known here without adding another layer of branching.
    void *addr_ptr = (void *)ctx->args[1];

    int res = bpf_probe_read_user(&e->data.raw_addr, sizeof(e->data.raw_addr), addr_ptr);
    if (res < 0) {
        bpf_ringbuf_discard(e, 0);
        return 0;
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

// Automatically extend tracking to child processes so that forked children
// are observed without requiring userspace to manually insert their PIDs.
SEC("tracepoint/sched/sched_process_fork")
int trace_forkAndClone(struct trace_event_raw_sched_process_fork *ctx) {
    __u32 pid = ctx->child_pid;
    __u32 ppid = bpf_get_current_pid_tgid() >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &ppid)) return 0;

    bpf_map_update_elem(&tracked_pids, &pid, &pid, BPF_ANY);

    return 0;
}


SEC("tracepoint/sched/sched_process_exit")
int trace_process_exit(struct trace_event_raw_sched_process_exit *ctx) {
    __u64 id = bpf_get_current_pid_tgid();
    __u32 tgid = id >> 32;
    __u32 tid = id;

    // sched_process_exit fires for every thread, but we only care about the
    // last thread exiting (tgid == tid), which represents the process itself.
    if (tgid != tid) return 0;

    __u32 pid = tgid;

    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;
    bpf_map_delete_elem(&tracked_pids, &pid);   // stop tracking — process is gone
    bpf_map_delete_elem(&heap_totals, &pid);

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;

    e->type = 2; // Exit event
    e->pid = pid;
    e->timestamp = bpf_ktime_get_ns();

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    bpf_ringbuf_submit(e, 0);

    return 0;
}


SEC("tracepoint/sched/sched_process_exec")
int trace_process_exec(struct trace_event_raw_sched_process_exec *ctx) {
    // Upper 32 bits = tgid (what userspace calls "pid"); lower 32 bits = tid.
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;

    e->type = 0; // Exec event
    e->pid = pid;
    e->timestamp = bpf_ktime_get_ns();

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    // __data_loc_filename is a BTF dynamic location field: its lower 16 bits
    // encode the offset from the start of the tracepoint context struct to
    // where the actual string data lives. Casting to uint16_t extracts that
    // offset, then we add it to ctx's base address to get a kernel pointer.
    __u16 filename_loc = (uint16_t)BPF_CORE_READ(ctx, __data_loc_filename);
    int res = bpf_probe_read_str(&e->data.fname, sizeof(e->data.fname), (void *)ctx + filename_loc);
    if (res < 0) {
        bpf_ringbuf_discard(e, 0);
        return 0;
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

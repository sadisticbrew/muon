// go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

char __license[] SEC("license") = "Dual MIT/GPL";

volatile const __u32 target_pid;

struct mmap_temp{
    __u32 pid;
    __u64 size;
};

struct mmap_event {
    __u64 addr;
    __u64 size;
};

struct event {
    __u32 pid;
    __u32 type;
    char comm[16];
    union {
        char fname[256];
        unsigned char raw_addr[128];
        struct mmap_event mmap_data;
    } data;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // 16 MB buffer
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 14);
    __type(key, __u32);
    __type(value, __u32);
} tracked_pids SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} drop_counter SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 14);
    __type(key, __u64);
    __type(value, struct mmap_temp);
} pending_mmaps SEC(".maps");

// ----------Helper funcs--------------
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

// --------------------------------------

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *ctx) {

    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;
    e->type = 1;

    e->pid =pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

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

    e->pid = pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    void *addr_ptr = (void *)ctx->args[1];

    int res = bpf_probe_read_user(&e->data.raw_addr, sizeof(e->data.raw_addr), addr_ptr);
    if (res < 0) {
        bpf_ringbuf_discard(e, 0);
        return 0;
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_mmap")
int trace_mmap(struct trace_event_raw_sys_enter *ctx){
    __u64 id =  bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 key = id;
    struct mmap_temp md = { .pid = pid, .size = ctx->args[1] };
    bpf_map_update_elem(&pending_mmaps, &key, &md, BPF_ANY);

    return 0;
}

SEC("tracepoint/syscalls/sys_exit_mmap")
int trace_mmap_exit(struct trace_event_raw_sys_exit *ctx){
    __u64 id =  bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 key = id;
    struct mmap_temp *md;
    md = bpf_map_lookup_elem(&pending_mmaps, &key);
    bpf_map_delete_elem(&pending_mmaps, &key);
    if (!(md)) return 0;
    if (md->pid != pid) return 0;

    long res = ctx->ret;
    if (res < 0) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;

    e->type = 4;
    e->pid = pid;
    bpf_get_current_comm(e->comm, sizeof(e->comm));
    e->data.mmap_data.addr = res;
    e->data.mmap_data.size = md->size;

    bpf_ringbuf_submit(e, 0);
    return 0;
}

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

    // Ignore temporary worker threads exiting
    if (tgid != tid) return 0;

    __u32 pid = tgid;

    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;
    bpf_map_delete_elem(&tracked_pids, &pid);

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;

    e->type = 2; // Exit event
    e->pid = pid;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    bpf_ringbuf_submit(e, 0);

    return 0;
}


SEC("tracepoint/sched/sched_process_exec")
int trace_process_exec(struct trace_event_raw_sched_process_exec *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;// bpf_get_current_pid_tgid() returns the thread group ID (which user space calls PID) in the upper 32 bits, and the thread ID in the lower 32 bits.
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (is_event_empty(e)) return 0;

    e->type = 0; // Exec event
    e->pid = pid;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    // Locate the filename
    __u16 filename_loc = (uint16_t)BPF_CORE_READ(ctx, __data_loc_filename);
    // Read the filename from the context
    int res = bpf_probe_read_str(&e->data.fname, sizeof(e->data.fname), (void *)ctx + filename_loc);
    if (res < 0) {
        bpf_ringbuf_discard(e, 0);
        return 0;
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

// go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

char __license[] SEC("license") = "Dual MIT/GPL";

volatile const __u32 target_pid;
volatile const __u16 ALLOC = 0;
volatile const __u16 FREE = 1;
volatile const __u16 FREE_NO_HISTORY = 2;


struct mmap_temp{
    __u32 pid;
    __u64 size;
};

struct brk_temp {
    __u64 old;
};

struct alloc_event {
    __u64 addr;
    __u64 size;
    __u16 flag;
};

struct alloc_key {
    __u64 addr;
    __u32 pid;
};

struct event {
    __u32 pid;
    __u32 type;
    char comm[16];
    __u64 timestamp;
    union {
        char fname[256];
        unsigned char raw_addr[128];
        struct alloc_event alloc_data;
    } data;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 26); // 64 MB buffer
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
    __uint(max_entries, 1 << 20);
    __type(key, __u64);
    __type(value, struct mmap_temp);
} pending_mmaps SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 20);
    __type(key, __u64);
    __type(value, struct brk_temp);
} pending_brks SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1 << 20);
    __type(key, struct alloc_key);
    __type(value, __u64);
} active_allocs SEC(".maps");

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
    __u64 addr = ctx->args[0];
    __u64 size = ctx->args[1];
    struct mmap_temp md = { .pid = pid, .size = size };

    /* add to pending mmaps to verify if the request is approved during exit */
    bpf_map_update_elem(&pending_mmaps, &key, &md, BPF_ANY);

    return 0;
}
SEC("tracepoint/syscalls/sys_exit_mmap")
int trace_mmap_exit(struct trace_event_raw_sys_exit *ctx){
    __u64 id =  bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    /* check if the mmap is pending */
    __u64 key = id;
    struct mmap_temp *md_ptr;
    md_ptr = (struct mmap_temp *)bpf_map_lookup_elem(&pending_mmaps, &key);
    if (!(md_ptr)) return 0;
    struct mmap_temp md = *md_ptr;
    bpf_map_delete_elem(&pending_mmaps, &key);
    if (md.pid != pid) return 0;

    /* check if the requested address was approved */
    long addr = ctx->ret;
    if (addr < 0) return 0;

    __u64 size = md.size;

    /* add the approved <k: addr, v: size> to active allocations */
    struct alloc_key alloc_key = {};  // zero entire struct first
    alloc_key.addr = addr;
    alloc_key.pid = pid;
    bpf_map_update_elem(&active_allocs, &alloc_key, &size, BPF_ANY);

    size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
    struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
    if (is_event_empty(e)) return 0;

    e->type = 4;
    e->pid = pid;
    bpf_get_current_comm(e->comm, sizeof(e->comm));
    e->timestamp = bpf_ktime_get_ns();
    e->data.alloc_data.addr = addr;
    e->data.alloc_data.size = size;
    e->data.alloc_data.flag = ALLOC;

    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_brk")
int trace_brk(struct trace_event_raw_sys_enter *ctx) {
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if(!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 req_addr = ctx->args[0];
    if (req_addr == 0) return 0;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();

    struct brk_temp curr_break = { .old = BPF_CORE_READ(task, mm, brk) };

    bpf_map_update_elem(&pending_brks, &id, &curr_break, BPF_ANY);

    return 0;
}
SEC("tracepoint/syscalls/sys_exit_brk")
int trace_brk_exit(struct trace_event_raw_sys_exit *ctx) {
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if(!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    struct brk_temp *old_break = bpf_map_lookup_elem(&pending_brks, &id);
    if (!old_break) return 0;
    bpf_map_delete_elem(&pending_brks, &id);

    __u64 new_brk = ctx->ret;
    if (new_brk == old_break->old) return 0;


    size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
    struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
    if (is_event_empty(e)) return 0;

    e->pid = pid;
    e->type = 5;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    e->timestamp = bpf_ktime_get_ns();
    if (new_brk > old_break->old) {
        e->data.alloc_data.size = new_brk - old_break->old;
        e->data.alloc_data.flag = ALLOC;
    } else {
        e->data.alloc_data.size = old_break->old - new_brk;
        e->data.alloc_data.flag = FREE;
    }
    e->data.alloc_data.addr = new_brk;



    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_munmap")
int trace_munmap(struct trace_event_raw_sys_enter *ctx) {
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if(!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 addr = ctx->args[0];
    if (addr == 0) return 0;
    __u64 req_size = ctx->args[1];
    if (req_size == 0) return 0;

    struct alloc_key alloc_key = {};
    alloc_key.addr = addr;
    alloc_key.pid = pid;

    /* check if the requested address is active */
    __u64 *active_size = bpf_map_lookup_elem(&active_allocs, &alloc_key);
    if (!active_size) {
        size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
        struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
        if (is_event_empty(e)) return 0;

        e->pid = pid;
        e->type = 4;
        bpf_get_current_comm(&e->comm, sizeof(e->comm));
        e->timestamp = bpf_ktime_get_ns();
        e->data.alloc_data.addr = addr;
        e->data.alloc_data.size = req_size;
        e->data.alloc_data.flag = FREE_NO_HISTORY;

        bpf_ringbuf_submit(e, 0);
        return 0;
    };

    __u64 freed_size;
    /*update the active allocation size in accordance with the requested size */
    if (*active_size == req_size) {
        bpf_map_delete_elem(&active_allocs, &alloc_key);
        freed_size = req_size;
    } else if (*active_size > req_size) {
        __u64 temp = *active_size - req_size;
        bpf_map_update_elem(&active_allocs, &alloc_key, &temp, BPF_ANY);
        freed_size = req_size;
    } else {
        return 0;
    }

    size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
    struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
    if (is_event_empty(e)) return 0;

    e->pid = pid;
    e->type = 4;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    e->timestamp = bpf_ktime_get_ns();
    e->data.alloc_data.addr = addr;
    e->data.alloc_data.size = freed_size;
    e->data.alloc_data.flag = FREE;

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

// go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>
#include "maps.c"
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

SEC("tracepoint/syscalls/sys_enter_mmap")
int trace_mmap(struct trace_event_raw_sys_enter *ctx){
    __u64 id =  bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 key = id;
    __u64 addr = ctx->args[0];
    __u64 size = ctx->args[1];
    struct mmap_temp md = { .pid = pid, .size = size };

    // Stash the requested size keyed by pid_tgid. The kernel may reject the
    // request (ret < 0 on exit), so we defer emitting any event until exit.
    bpf_map_update_elem(&pending_mmaps, &key, &md, BPF_ANY);

    return 0;
}

SEC("tracepoint/syscalls/sys_exit_mmap")
int trace_mmap_exit(struct trace_event_raw_sys_exit *ctx){
    __u64 id =  bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if (!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    __u64 key = id;
    struct mmap_temp *md_ptr;
    md_ptr = (struct mmap_temp *)bpf_map_lookup_elem(&pending_mmaps, &key);
    if (!(md_ptr)) return 0;
    struct mmap_temp md = *md_ptr;      // copy before deleting to avoid a dangling pointer
    bpf_map_delete_elem(&pending_mmaps, &key);
    if (md.pid != pid) return 0;       // shouldn't happen, but guards against key collisions

    // mmap returns the mapped address on success, or a negative errno cast to long.
    long addr = ctx->ret;
    if (addr < 0) return 0;

    __u64 size = md.size;

    // Record the live region so munmap can later compute freed bytes accurately.
    struct alloc_key alloc_key = {};  // zero entire struct first to avoid padding-byte garbage in map key
    alloc_key.addr = addr;
    alloc_key.pid = pid;
    bpf_map_update_elem(&active_allocs, &alloc_key, &size, BPF_ANY);

    // Reserve only as many bytes as actually needed for this event variant.
    // Sending sizeof(struct event) would waste ~250 bytes per alloc event.
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

    __u64 *current_heap = bpf_map_lookup_elem(&heap_totals, &pid);
    if (current_heap) {
        __sync_fetch_and_add(current_heap, size);
    } else {
        bpf_map_update_elem(&heap_totals, &pid, &size, BPF_ANY);
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_brk")
int trace_brk(struct trace_event_raw_sys_enter *ctx) {
    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;
    if(!bpf_map_lookup_elem(&tracked_pids, &pid)) return 0;

    // brk(0) is a probe call used to query the current break — no allocation
    // is intended, so there's nothing to track.
    __u64 req_addr = ctx->args[0];
    if (req_addr == 0) return 0;

    // Snapshot the current heap break from the kernel's mm_struct. We need
    // this now because by the time sys_exit fires, the value has already changed.
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
    // If brk() returns the same address it was given, the kernel rejected the
    // request (ENOMEM). Nothing changed, so nothing to report.
    if (new_brk == old_break->old) return 0;

    // size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
    // struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
    // if (is_event_empty(e)) return 0;


    // brk can grow or shrink the heap. Compute the delta and set the flag
    // accordingly so userspace doesn't need to track direction itself.
    __u64 delta;
    __u16 flag;
    if (new_brk > old_break->old) {
        delta = new_brk - old_break->old;
        flag = ALLOC;
    } else {
        delta = old_break->old - new_brk;
        flag = FREE;
    }
    __u64 *current_heap = bpf_map_lookup_elem(&heap_totals, &pid);
    if (current_heap) {
        if (flag == ALLOC) {
            __sync_fetch_and_add(current_heap, delta);
        } else {
            if (*current_heap >= delta) {
                __sync_fetch_and_sub(current_heap, delta);
            }
        }
    } else {
        bpf_map_update_elem(&heap_totals, &pid, &delta, BPF_ANY);
    }

    size_t reserve_size = offsetof(struct event, data) + sizeof(struct alloc_event);
    struct event *e = bpf_ringbuf_reserve(&events, reserve_size, 0);
    if (is_event_empty(e)) return 0;

    e->pid = pid;
    e->type = 5;
    e->timestamp = bpf_ktime_get_ns();
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    e->data.alloc_data.size = delta;
    e->data.alloc_data.flag = flag;
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

    // If there's no entry in active_allocs, the mmap happened before we attached
    // (or was made by an untracked ancestor). We still emit an event so userspace
    // can reconcile its accounting, tagged FREE_NO_HISTORY.
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
    // Handle partial and full unmaps. The kernel allows unmapping a sub-region,
    // so we shrink the tracked size rather than deleting the key outright.
    // If someone tries to unmap more than we have recorded, we bail — this
    // indicates a bookkeeping inconsistency and is safer to ignore than to misreport.
    if (*active_size == req_size) {
        bpf_map_delete_elem(&active_allocs, &alloc_key);
        freed_size = req_size;
    } else if (*active_size > req_size) {
        __u64 temp = *active_size - req_size;
        bpf_map_update_elem(&active_allocs, &alloc_key, &temp, BPF_ANY);
        freed_size = req_size;
    } else {
        bpf_map_delete_elem(&active_allocs, &alloc_key);
        freed_size = req_size;
        // return 0;
    }

    __u64 *current_heap = bpf_map_lookup_elem(&heap_totals, &pid);
    if (current_heap) {
        // Prevent underflow just in case VMA merging gets weird
        if (*current_heap >= freed_size) {
            __sync_fetch_and_sub(current_heap, freed_size); // Atomic sub
        } else {
            __u64 zero = 0;
            bpf_map_update_elem(&heap_totals, &pid, &zero, BPF_ANY);
        }
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

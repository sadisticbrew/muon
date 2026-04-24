//go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

char __license[] SEC("license") = "Dual MIT/GPL";

volatile const __u32 target_pid;



struct event {
    __u32 pid;
    __u32 type;
    char comm[16];
    char fname[256];
    // struct connect_call call;
    unsigned char raw_addr[128];
};



struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // 16 MB buffer
    // __uint(max_entries, 256 * 1024); // 16 MB buffer

} events SEC(".maps");

SEC("socket") int const_example() {
    return target_pid;
}

SEC("tracepoint/syscalls/sys_enter_execve")
int trace_execve(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (target_pid != 0 && pid != target_pid) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        static const char fmt[] = "THE BUFFER IS FULL!";
        bpf_trace_printk(fmt, sizeof(fmt));
        return 0;} // Drop event if buffer is full
    e->type = 0;
    e->pid = pid;
    // bpf_get_current_pid_tgid() returns the thread group ID (which user space calls PID)
    // in the upper 32 bits, and the thread ID in the lower 32 bits.

    char *filename = (char *)ctx->args[0];
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    int res = bpf_probe_read_user_str(&e->fname, sizeof(e->fname), filename);



    bpf_ringbuf_submit(e, 0);

    return 0;
}

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (target_pid != 0 && pid != target_pid) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    e->type = 1;

    e->pid =pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    char *fname = (char *)ctx->args[1];
    int res = bpf_probe_read_user_str(&e->fname, sizeof(e->fname), fname);


    bpf_ringbuf_submit(e, 0);

    return 0;
}

SEC("tracepoint/syscalls/sys_enter_exit")
int trace_exit(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (target_pid != 0 && pid != target_pid) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    e->type = 2;

    e->pid = pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    int res = (int)ctx->args[0];
    if (res != 0) {

        bpf_ringbuf_discard(e, 0);
        return 0;
    }


    bpf_ringbuf_submit(e, 0);

    return 0;
}

SEC("tracepoint/syscalls/sys_enter_connect")
int trace_connect(struct trace_event_raw_sys_enter *ctx) {
    char msg[] = "Target PID: %lu\n";
    bpf_trace_printk(msg, sizeof(msg), (unsigned long)target_pid);
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    char msg2[] = "Target PID: %u, current PID: %u\n";
    bpf_trace_printk(msg2, sizeof(msg2), target_pid, pid);
    if (target_pid != 0 && pid != target_pid) return 0;

    struct event *e;
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;
    e->type = 3;

    e->pid = pid;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    void *addr_ptr = (void *)ctx->args[1];

    bpf_probe_read_user(&e->raw_addr, sizeof(e->raw_addr), addr_ptr);

    bpf_ringbuf_submit(e, 0);
    return 0;
}

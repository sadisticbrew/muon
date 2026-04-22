//go:build ignore

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
// License must be GPL-compatible to use many eBPF helpers
char __license[] SEC("license") = "Dual MIT/GPL";

// The data we want to send to user space
struct event {
    __u32 pid;
    __u32 type;
    char comm[16];
    char fname[256];

};

// Define a ring buffer map
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // 16 MB buffer
} events SEC(".maps");

// Attach to the openat syscall tracepoint
SEC("tracepoint/syscalls/sys_enter_execve")
int trace_execve(struct trace_event_raw_sys_enter *ctx) {
    struct event *e;

    // Reserve space in the ring buffer
    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0; // Drop event if buffer is full
    // bpf_get_current_pid_tgid() returns the thread group ID (which user space calls PID)
    // in the upper 32 bits, and the thread ID in the lower 32 bits.
    e->pid = bpf_get_current_pid_tgid() >> 32;

    char *filename = (char *)ctx->args[0];
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    int res = bpf_probe_read_user_str(&e->fname, sizeof(e->fname), filename);


    e->type = 0;
    // Submit the event
    bpf_ringbuf_submit(e, 0);


    return 0;
}

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *ctx) {
    struct event *e;

    e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    e->pid = bpf_get_current_pid_tgid() >> 32;

    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    char *fname = (char *)ctx->args[1];
    int res = bpf_probe_read_user_str(&e->fname, sizeof(e->fname), fname);

    e->type = 1;

    bpf_ringbuf_submit(e, 0);

    return 0;
}

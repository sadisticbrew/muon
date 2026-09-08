# Muon

Muon is an eBPF based X-ray for compiled binaries. Attach it to a running process and it streams every file it opens, every connection it makes and every chunk of memory it allocates -- read straight out of the kernel, without stopping or modifying the program.

It ships as a single Go binary. You run it, watch what the process actually does, and Ctrl-C when you're done.

## Why

Compiled programs are black boxes. When a Go or Rust or C backend starts leaking memory, making weird network calls or crashing for no obvious reason, you can't `println` your way into it. And it's getting worse now that AI is writing large chunks of code nobody fully understands.

The existing tools didn't work for me:

- `strace` uses ptrace, which stops the process at every syscall. Fine for a quick peek, painful under real load.
- The modern eBPF tooling is mostly enterprise observability suites built for server clusters. I just wanted to look inside a process on my laptop.

So I wrote Muon: attach to a PID, watch the syscalls stream by, detach. Overhead stays low because the filtering happens in kernel space -- only events from the process tree you're attached to ever reach userspace.

## Benchmarks

I benchmarked Muon against `perf trace` and `strace` on a machine with a locked CPU governor, running each workload repeatedly and averaging the runs. These numbers are from my machine so treat them as directional, but the gap between ptrace and eBPF is not subtle.

### Workload 1: process creation (10,000 execs)

Spin up and tear down 10,000 processes as fast as the machine allows.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| Baseline (no tracing) | 8.154s | 0% | ±0.039s |
| Muon (eBPF) | 9.190s | ~12.7% | ±0.022s |
| perf trace | 13.656s | ~67.4% | ±0.087s |
| strace (ptrace) | 19.928s | ~144.3% | ±0.104s |

Fork/exec is the worst case for tracing tools -- every process in the tree fires events at once. Muon adds ~12.7%; strace more than doubles the runtime.

### Workload 2: memory stress (sustained mmap allocations)

45 seconds of relentless memory allocations.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| Baseline (no tracing) | 44.852s | 0% | ±0.480s |
| Muon (eBPF) | 45.124s | ~0.6% | ±0.518s |
| perf trace | 46.152s | ~2.9% | ±0.864s |
| strace (ptrace) | 46.756s | ~4.2% | ±2.025s |

At 0.6%, Muon's overhead is inside the noise of the OS itself.

### Workload 3: high-frequency file ops (300,000 openat calls)

Flood the system with file opens and see who drowns.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| Baseline (no tracing) | 3.228s | 0% | ±0.071s |
| Muon (eBPF) | 3.180s\* | ~0% | ±0.089s |
| perf trace | 4.730s | ~46.5% | ±0.051s |
| strace (ptrace) | 6.392s | ~98.0% | ±0.069s |

\*Muon finished faster than the baseline here. The difference sits within the standard deviation (±0.089s), so the honest reading is: file I/O tracing overhead is zero.

## What it tracks

- `exec` and process exits, with child processes followed automatically via `sched_process_fork` -- you see the whole process tree, not just the PID you attached to
- `openat` for file access
- `connect`, with the raw sockaddr parsed in userspace (IPv4, IPv6 and Unix sockets)
- `mmap`, `brk` and `munmap`, so you can watch allocation patterns and spot leaks live

The PID check sits inside every tracepoint handler in the kernel-side code. Events from processes you don't care about get dropped before they ever touch the ring buffer. That one `if` is most of the reason the overhead is this low.

Since everything comes out as structured events, dumping the stream as JSON for an LLM to reason about is a natural next step (see roadmap).

## Architecture

C in the kernel, Go in userspace.

- Kernel probes are written in C against `vmlinux.h` for CO-RE support -- compile once, run across kernel versions.
- Userspace is Go, loading the probes with `cilium/ebpf` and draining events.
- The two talk over a 64MB BPF ring buffer, so high-frequency bursts don't drop events.

## Build

You need:

- Linux 5.8+ (ring buffer support)
- `clang`, `llvm` and `bpftool`
- Go 1.24+

```bash
make vmlinux   # generate kernel headers
make run       # build and run
```

## Roadmap

- [x] PPID tracking -- follow the whole process tree
- [x] Memory tracing (mmap/brk/munmap)
- [ ] Deeper memory tracing -- hook malloc/free instead of raw syscalls
- [ ] JSON export formatted for LLM context windows
- [ ] TUI dashboard (right now it just logs)
- [ ] Live leaked-memory totals
- [ ] Filtering by UID/GID or filename

---

**Author**: Pratham Patel
**License**: Dual MIT/GPL

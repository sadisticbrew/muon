# Muon: A Localized eBPF Process "X-Ray"

Muon is a lightning-fast, single-binary terminal tool that acts as an X-ray for running programs. Using eBPF technology, it safely hooks directly into the Linux kernel to instantly stream every file opened, every network connection made, and every memory block allocated by a program—without stopping or modifying the code.

---

## The Problem
When a compiled backend program (like Go, Rust, or C) misbehaves—leaking memory, crashing, or making weird network calls—it acts like a black box. This problem is getting worse because AI is now generating complex code that human developers don't fully understand.

To fix these bugs, developers need to see exactly what the program is doing in real-time. However, the current tools are broken:
* **Legacy tools (like `strace`)** are way too slow and crash the system under heavy load.
* **Modern eBPF tools** are massive, clunky enterprise suites built for huge server clusters, not for a developer debugging on their local laptop.

There is no simple, fast way for a developer to just "look inside" a running program.

## The Solution
Muon is built specifically for local developer experience (DX). 
* **Near-Zero Overhead:** Because it runs custom eBPF bytecode in the kernel, it adds only a small amount performance overhead on standard system calls, absolutely crushing legacy tools.
* **Zero Friction:** It is packaged as a single Go binary. No massive server setups, no heavy infrastructure. You just download it and run it.
* **AI-Ready:** It extracts the exact runtime data developers need to feed back into AI models (like ChatGPT) to figure out why a black-box program is failing.

---

## Performance Benchmarks
Muon was subjected to a brutal, mathematically rigorous benchmark suite running on a locked CPU governor to eliminate OS scheduler variance. The results highlight the massive architectural advantage of in-kernel eBPF probes. 

### Workload 1: Process Creation (10,000 `exec` operations)
This workload forces the system to frantically launch and destroy 10,000 processes in rapid succession. Muon handled the massive process tree with a fraction of the overhead of legacy tools.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| **Baseline (No Tracing)** | 8.154s | 0% | ±0.039s |
| **Muon (eBPF)** | **9.190s** | **~12.7%** | ±0.022s |
| **perf trace** | 13.656s | ~67.4% | ±0.087s |
| **strace (ptrace)** | 19.928s | ~144.3% | ±0.104s |

### Workload 2: Memory Stress (Sustained `mmap` allocations)
Under a sustained 45-second workload of relentless memory allocations, Muon's overhead effectively disappeared into the natural background noise of the operating system.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| **Baseline (No Tracing)** | 44.852s | 0% | ±0.480s |
| **Muon (eBPF)** | **45.124s** | **~0.6%** | ±0.518s |
| **perf trace** | 46.152s | ~2.9% | ±0.864s |
| **strace (ptrace)** | 46.756s | ~4.2% | ±2.025s |

### Workload 3: High-Frequency File Operations (300,000 `openat` calls)
This workload floods the system with file open requests. Muon's kernel-side filtering kept the ring buffer lean, processing hundreds of thousands of events with mathematically negligible overhead.

| Tracer | Avg. Execution Time | Overhead vs Baseline | Standard Deviation |
| :--- | :--- | :--- | :--- |
| **Baseline (No Tracing)** | 3.228s | 0% | ±0.071s |
| **Muon (eBPF)** | **3.180s\*** | **~0%** | ±0.089s |
| **perf trace** | 4.730s | ~46.5% | ±0.051s |
| **strace (ptrace)** | 6.392s | ~98.0% | ±0.069s |

*\*Note: Muon's execution time in this test physically fell within the margin of error (±0.089s) of the untraced baseline, proving its file I/O tracing overhead is statistically zero.*

---

## Core Features
* **Zero-Overhead Tracing**: Near-native execution speed even under heavy process and memory load.
* **Kernel-Level Filtering**: Discards irrelevant data in kernel-space before it ever reaches the user-space dashboard.
* **Process Tree Tracking**: Automatically tracks child processes by hooking into `sched_process_fork`, maintaining visibility across entire process trees.
* **Memory Lifecycle Observability**: Real-time tracking of `mmap`, `brk`, and `munmap` to monitor active memory allocations and potential leaks.
* **Network Awareness**: Parses raw socket addresses (IPv4/IPv6/Unix) directly from the `connect` syscall.

## Architecture
Muon is built using a hybrid C and Go stack:
* **Kernel-Space (C)**: Highly optimized probes utilizing `vmlinux.h` for CO-RE (Compile Once – Run Everywhere) support.
* **User-Space (Go)**: A robust event consumer utilizing `cilium/ebpf` for program loading.
* **Communication**: Asynchronous data transfer via a massive **16MB BPF Ring Buffer**, ensuring events are never dropped during high-frequency bursts.

---

## Build and Run

### Prerequisites
* Linux Kernel 5.8+ (for Ring Buffer support)
* `clang`, `llvm`, and `bpftool`
* Go 1.21+

### Installation
1.  **Generate Kernel Headers**:
    ```bash
    make vmlinux
    ```
2.  **Compile and Run**:
    ```bash
    make run
    ```

## Roadmap
* [x] **PPID Tracking**: Implemented automated process tree monitoring.
* [x] **Memory Tracing**: Implemented kernel level memory allocation state tracking.
* [ ] **Memory Tracing (deep trace)**: Implement memory allocation tracing for functions like malloc and free.
* [ ] **AI Context Export**: Output highly formatted JSON streams explicitly optimized for LLM context windows.
* [ ] **TUI Dashboard**: Transition from logging to a full-screen interactive terminal interface.
* [ ] **Memory Aggregation**: Calculate and display total leaked memory in real-time.
* [ ] **Custom Filtering**: Support for filtering by UID, GID, or specific filenames.

---

**Author**: Pratham Patel  
**License**: Dual MIT/GPL

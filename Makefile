BINARY_NAME=muon
BPF_SOURCE=muon.c
GO_FILES=$(shell find . -type f -name '*.go')

CLANG ?= clang
STRIP ?= llvm-strip
BPFTOOL ?= bpftool

export ARCH ?= $(shell uname -m | sed 's/x86_64/x86/' \
			 | sed 's/arm.*/arm/' \
			 | sed 's/aarch64/arm64/' \
			 | sed 's/ppc64le/powerpc/' \
			 | sed 's/mips.*/mips/' \
			 | sed 's/riscv64/riscv/' \
			 | sed 's/loongarch64/loongarch/')

.PHONY: all generate build run clean vmlinux

all: vmlinux generate build

# Generate vmlinux.h from the running kernel (requires bpftool)
vmlinux:
	@if [ ! -f bpf/vmlinux.h ]; then \
		echo "Generating vmlinux.h..."; \
		$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > bpf/vmlinux.h; \
	fi

generate: vmlinux
	go generate ./...

build: generate
	go build -o $(BINARY_NAME) .

run: build
	sudo ./$(BINARY_NAME)

clean:
	go clean
	rm -f $(BINARY_NAME)
	find . -type f -name '*_bpfel.*' -delete
	find . -type f -name '*_bpfeb.*' -delete

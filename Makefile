# Project Variables
BINARY_NAME=muon
BPF_SOURCE=muon.c
GO_FILES=$(shell find . -type f -name '*.go')

CLANG ?= clang
STRIP ?= llvm-strip
BPFTOOL ?= bpftool

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
	rm -f bpf_bpfeb.go bpf_bpfel.go bpf_bpfeb.o bpf_bpfel.o

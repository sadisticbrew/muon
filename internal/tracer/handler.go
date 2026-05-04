package tracer

import (
	"fmt"
	"log"
	"muon/internal/ebpf"
	"time"

	"github.com/dustin/go-humanize"
)

var handlers = map[uint32]func(Event, *ebpf.MuonObjects) ParsedEvent{
	0: handleExec,
	1: handleOpenat,
	2: handleExit,
	3: handleConnect,
	4: handleMmap,
	5: handleBrk,
}

var eventKindMap = map[uint32]string{
	0: "exec",
	1: "openat",
	2: "exit",
	3: "connect",
	4: "mmap",
	5: "brk",
}

func handleExec(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	fname := makeFilename(event)
	log.Printf("[exec] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
	return ParsedEvent{
		PID:       event.PID,
		Comm:      cleanString(event.Comm),
		Timestamp: time.Now().UnixMicro(),
		Kind:      eventKindMap[event.Type],
		Detail:    fmt.Sprintf("filename: %s", fname),
	}
}

func handleOpenat(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	fname := makeFilename(event)
	log.Printf("[openat] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
	return ParsedEvent{
		PID:       event.PID,
		Comm:      cleanString(event.Comm),
		Timestamp: time.Now().UnixMicro(),
		Kind:      eventKindMap[event.Type],
		Detail:    fmt.Sprintf("filename: %s", fname),
	}
}

func handleExit(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	log.Printf("[exit] pid: %d, comm: %s\n", event.PID, string(event.Comm[:]))
	cleanupAfterExit(objs, event.PID)
	return ParsedEvent{
		PID:       event.PID,
		Comm:      cleanString(event.Comm),
		Timestamp: time.Now().UnixMicro(),
		Kind:      eventKindMap[event.Type],
		Detail:    "",
	}
}

func handleConnect(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	addr, port := parseRawAddr(event)
	return ParsedEvent{
		PID:       event.PID,
		Comm:      cleanString(event.Comm),
		Timestamp: time.Now().UnixMicro(),
		Kind:      eventKindMap[event.Type],
		Detail:    fmt.Sprintf("addr: %s:%d", addr, port),
	}
}

func handleMmap(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	allocData, err := parseAllocEvent(event)
	if err != nil {
		log.Println("Failed to parse alloc_data:", err)
		return ParsedEvent{}
	}
	switch allocData.Flag {
	case ALLOC:
		log.Printf("[mmap] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
		return ParsedEvent{
			PID:       event.PID,
			Comm:      cleanString(event.Comm),
			Timestamp: time.Now().UnixMicro(),
			Kind:      "mmap",
			Detail:    fmt.Sprintf("size: %s, addr: %x", humanize.Bytes(allocData.Size), allocData.Addr),
		}
	case FREE:
		log.Printf("[munmap] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
		return ParsedEvent{
			PID:       event.PID,
			Comm:      cleanString(event.Comm),
			Timestamp: time.Now().UnixMicro(),
			Kind:      "munmap",
			Detail:    fmt.Sprintf("size: %s, addr: %x", humanize.Bytes(allocData.Size), allocData.Addr),
		}
	case FREE_NO_HISTORY:
		log.Printf("[munmap_no_history] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
		return ParsedEvent{
			PID:       event.PID,
			Comm:      cleanString(event.Comm),
			Timestamp: time.Now().UnixMicro(),
			Kind:      "munmap_no_history",
			Detail:    fmt.Sprintf("size: %s, addr: %x", humanize.Bytes(allocData.Size), allocData.Addr),
		}
	}
	return ParsedEvent{}
}

func handleBrk(event Event, objs *ebpf.MuonObjects) ParsedEvent {
	brkData, err := parseAllocEvent(event)
	if err != nil {
		fmt.Println("Failed to parse brk_data:", err)
		return ParsedEvent{}
	}
	log.Printf("[brk] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(brkData.Size), brkData.Addr)
	return ParsedEvent{
		PID:       event.PID,
		Comm:      cleanString(event.Comm),
		Timestamp: time.Now().UnixMicro(),
		Kind:      eventKindMap[event.Type],
		Detail:    fmt.Sprintf("size: %s, addr: %x", humanize.Bytes(brkData.Size), brkData.Addr),
	}
}

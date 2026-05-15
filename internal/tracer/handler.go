package tracer

import (
	"muon/internal/ebpf"
	"unsafe"
)

// Changed payload to []byte to read it safely
var handlers = []func(*EventHeader, *ebpf.MuonObjects, *ParsedEvent, []byte){
	handleExec,
	handleOpenat,
	handleExit,
	handleConnect,
	handleMmap,
	handleBrk,
}

var eventKindMap = []string{
	"exec",
	"openat",
	"exit",
	"connect",
	"mmap",
	"brk",
}

func handleExec(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.Kind = eventKindMap[event.Type]
	copy(parsedEventPtr.Detail[:], payload)
}

func handleOpenat(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.Kind = eventKindMap[event.Type]
	copy(parsedEventPtr.Detail[:], payload)
}

func handleExit(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	// Make send non-blocking to prevent locking up the fast ring buffer loop
	select {
	case cleanupChan <- event.PID:
	default:
	}
	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.Kind = eventKindMap[event.Type]
	copy(parsedEventPtr.Detail[:], payload)
}

func handleConnect(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.Kind = eventKindMap[event.Type]
	copy(parsedEventPtr.Detail[:], payload)
}

func handleMmap(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	// Safe to extract because we ensure length > 18 in monitor.go
	allocData := *(*AllocEventData)(unsafe.Pointer(unsafe.SliceData(payload)))

	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.RawSize = allocData.Size
	parsedEventPtr.RawAddr = allocData.Addr
	parsedEventPtr.Flag = allocData.Flag

	switch allocData.Flag {
	case ALLOC:
		parsedEventPtr.Kind = "mmap"
	case FREE:
		parsedEventPtr.Kind = "munmap"
	case FREE_NO_HISTORY:
		parsedEventPtr.Kind = "munmap_no_history"
		parsedEventPtr.RawAddr = allocData.Addr
	}
}

func handleBrk(event *EventHeader, objs *ebpf.MuonObjects, parsedEventPtr *ParsedEvent, payload []byte) {
	brkData := *(*AllocEventData)(unsafe.Pointer(unsafe.SliceData(payload)))
	parsedEventPtr.PID = event.PID
	parsedEventPtr.Comm = event.Comm
	parsedEventPtr.Timestamp = event.Timestamp
	parsedEventPtr.Kind = eventKindMap[event.Type]
	parsedEventPtr.RawAddr = brkData.Addr
	parsedEventPtr.RawSize = brkData.Size
	parsedEventPtr.Flag = brkData.Flag
}

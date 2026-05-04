package tracer

import (
	"fmt"
	"log"
	"muon/internal/ebpf"

	"github.com/dustin/go-humanize"
)

var handlers = map[uint32]func(Event, *ebpf.MuonObjects){
	0: handleExec,
	1: handleOpenat,
	2: handleExit,
	3: handleConnect,
	4: handleMmap,
	5: handleBrk,
}

func handleExec(event Event, objs *ebpf.MuonObjects) {
	fname := makeFilename(event)
	log.Printf("[exec] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
}

func handleOpenat(event Event, objs *ebpf.MuonObjects) {
	fname := makeFilename(event)
	log.Printf("[openat] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
}

func handleExit(event Event, objs *ebpf.MuonObjects) {
	log.Printf("[exit] pid: %d, comm: %s\n", event.PID, string(event.Comm[:]))
	cleanupAfterExit(objs, event.PID)
}

func handleConnect(event Event, objs *ebpf.MuonObjects) {
	parseRawAddr(event)

}

func handleMmap(event Event, objs *ebpf.MuonObjects) {
	allocData, err := parseAllocEvent(event)
	if err != nil {
		log.Println("Failed to parse alloc_data:", err)
		return
	}
	switch allocData.Flag {
	case ALLOC:
		log.Printf("[mmap] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
	case FREE:
		log.Printf("[munmap] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
	case FREE_NO_HISTORY:
		log.Printf("[munmap_no_history] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(allocData.Size), allocData.Addr)
	}
}

func handleBrk(event Event, objs *ebpf.MuonObjects) {
	brkData, err := parseAllocEvent(event)
	if err != nil {
		fmt.Println("Failed to parse brk_data:", err)
		return
	}
	log.Printf("[brk] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(brkData.Size), brkData.Addr)
}

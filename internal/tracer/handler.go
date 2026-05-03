package tracer

import (
	"fmt"
	"log"

	"github.com/dustin/go-humanize"
)

var handlers = map[uint32]func(Event){
	0: handleExec,
	1: handleOpenat,
	2: handleExit,
	3: handleConnect,
	4: handleMmap,
	5: handleBrk,
}

func handleExec(event Event) {
	fname := makeFilename(event)
	log.Printf("[exec] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
}

func handleOpenat(event Event) {
	fname := makeFilename(event)
	log.Printf("[openat] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
}

func handleExit(event Event) {
	log.Printf("[exit] pid: %d, comm: %s\n", event.PID, string(event.Comm[:]))
}

func handleConnect(event Event) {
	parseRawAddr(event)

}

func handleMmap(event Event) {
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

func handleBrk(event Event) {
	brkData, err := parseAllocEvent(event)
	if err != nil {
		fmt.Println("Failed to parse brk_data:", err)
		return
	}
	log.Printf("[brk] - pid: %d, comm: %s, size: %s, addr: %x\n", event.PID, string(event.Comm[:]), humanize.Bytes(brkData.Size), brkData.Addr)
}

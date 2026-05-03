package tracer

import (
	"bytes"
	"encoding/binary"
	"log"
	"net/netip"
	"syscall"
)

func parseRawAddr(event Event) {
	family := binary.NativeEndian.Uint16(event.Data[0:2])
	log.Println(family)
	switch family {
	case syscall.AF_INET:
		port := binary.BigEndian.Uint16(event.Data[2:4])
		addr, ok := netip.AddrFromSlice(event.Data[4:8])
		if !ok {
			log.Println("Invalid address: ", event.Data[4:8])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_INET6:
		port := binary.BigEndian.Uint16(event.Data[2:4])
		addr, ok := netip.AddrFromSlice(event.Data[8:24])
		if !ok {
			log.Println("Invalid address: ", event.Data[8:24])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_UNIX:
		addr := string(bytes.Trim(event.Data[2:], "\x00"))
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s\n", event.PID, string(event.Comm[:]), addr)
	}
}

func makeFilename(event Event) string {
	nullIdx := bytes.Index(event.Data[:], []byte{0})
	var fname string
	if nullIdx == -1 {
		fname = string(event.Data[:])
	} else {
		fname = string(event.Data[:nullIdx])
	}
	return fname
}
func parseAllocEvent(event Event) (AllocEventData, error) {
	var data AllocEventData
	err := binary.Read(bytes.NewReader(event.Data[:]), binary.LittleEndian, &data)
	return data, err
}

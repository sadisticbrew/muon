package tracer

import (
	"bytes"
	"encoding/binary"
	"log"
	"net/netip"
	"syscall"
)

func ParseRawAddr(event *ParsedEvent) (string, uint16) {
	family := binary.NativeEndian.Uint16(event.Detail[0:2])
	switch family {
	case syscall.AF_INET:
		port := binary.BigEndian.Uint16(event.Detail[2:4])
		addr, ok := netip.AddrFromSlice(event.Detail[4:8])
		if !ok {
			log.Println("Invalid address: ", event.Detail[4:8])
		}
		// log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
		return addr.String(), port
	case syscall.AF_INET6:
		port := binary.BigEndian.Uint16(event.Detail[2:4])
		addr, ok := netip.AddrFromSlice(event.Detail[8:24])
		if !ok {
			log.Println("Invalid address: ", event.Detail[8:24])
		}
		// log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
		return addr.String(), port

	case syscall.AF_UNIX:
		addr := string(bytes.Trim(event.Detail[2:], "\x00"))
		// log.Printf("[connnect] pid: %d, comm: %s, addr: %s\n", event.PID, string(event.Comm[:]), addr)

		return addr, 0
	}
	return "", 0
}
func getNullIdx(b [256]byte) int {
	for i, c := range b {
		if c == 0 {
			return i
		}
	}
	return 255
}
func MakeFilename(event *ParsedEvent) string {
	nullIdx := bytes.Index(event.Detail[:], []byte{0})
	var fname string
	if nullIdx == -1 {
		fname = string(event.Detail[:])
	} else {
		fname = string(event.Detail[:nullIdx])
	}
	return fname
}
func CleanString(b [16]byte) string {
	nullIdx := bytes.Index(b[:], []byte{0})
	if nullIdx == -1 {
		return string(b[:])
	}
	return string(b[:nullIdx])
}

func (e *ParsedEvent) cmpParsedEvent(other *ParsedEvent) bool {
	if e.PID != other.PID {
		return false
	}
	if e.Comm != other.Comm {
		return false
	}
	if e.Kind != other.Kind {
		return false
	}
	if e.RawSize != other.RawSize {
		return false
	}
	if e.Flag != other.Flag {
		return false
	}
	return true
}

package tracer

import (
	"sync"
	"time"
)

const (
	ALLOC           uint16 = 0
	FREE            uint16 = 1
	FREE_NO_HISTORY uint16 = 2
)

type Event struct {
	PID  uint32
	Type uint32
	Comm [16]byte
	Data [256]byte
}

type AllocEventData struct {
	Addr uint64
	Size uint64
	Flag uint16
}

type AllocKey struct {
	Addr uint64
	PID  uint32
}

type ParsedEvent struct {
	PID       uint32
	Comm      string
	Timestamp time.Time
	Kind      string // "mmap", "munmap", "exec", "openat", etc.
	Detail    string // "addr: 0x7f... size: 4KB" — pre-formatted for display
}

type MuonState struct {
	mu           *sync.Mutex
	ActiveMemory int64
	PeakMemory   int64
	TotalAllocd  uint64
	TotalFreed   uint64
	RecentEvents []ParsedEvent
	DropCount    uint64
}

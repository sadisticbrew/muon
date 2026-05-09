package tui

import (
	"fmt"
	"log"
	"strings"

	"muon/internal/tracer"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/dustin/go-humanize"
)

var (
	baseBorder = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("240"))

	headerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("86")).
			Bold(true).
			Padding(0, 1)

	boxTitleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("205")).
			Bold(true).
			MarginBottom(1)

	footerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")).
			Padding(0, 1)

	// Pre-render static titles once to avoid string allocation on every View() tick
	eventStreamTitle = boxTitleStyle.Render("▼ EVENT STREAM") + "\n"
	memTrackerTitle  = boxTitleStyle.Render("▼ MEMORY TRACKER") + "\n"
)

type Model struct {
	width     int
	height    int
	parentPID uint32
	state     *tracer.MuonState
	viewport  viewport.Model

	eventLog      []string
	lastTimestamp uint64
}

func New(targetPid uint32) Model {
	vp := viewport.New(0, 0)

	return Model{
		parentPID: targetPid,
		viewport:  vp,
		eventLog:  make([]string, 0, 500),
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.viewport.Width = m.width - 4
		m.viewport.Height = m.height - 14

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			log.Println("Exiting Muon...")
			return m, tea.Quit
		}

	case *tracer.MuonState:
		m.state = msg
		m.updateLog(msg.RecentEvents)
		return m, nil
	}

	m.viewport, cmd = m.viewport.Update(msg)
	return m, cmd
}

func (m Model) View() string {
	if m.width == 0 || m.state == nil {
		return "Initializing..."
	}

	header := headerStyle.Render(fmt.Sprintf(
		"MUON │ Target PID: %d │ Kernel Drops: %d │ Userspace Drops: %d",
		m.parentPID, m.state.DropCount, m.state.UspaceDrops,
	))

	eventBox := baseBorder.
		Width(m.width - 4).
		Height(m.height - 12).
		Render(
			eventStreamTitle + m.viewport.View(),
		)

	activeMem := m.state.ActiveMemory
	if activeMem < 0 {
		activeMem = 0
	}

	memoryBox := baseBorder.
		Width(m.width - 4).
		Render(
			memTrackerTitle +
				fmt.Sprintf("Active: %s  │  Peak: %s",
					humanize.Bytes(uint64(activeMem)),
					humanize.Bytes(uint64(m.state.PeakMemory))),
		)

	footer := footerStyle.Render("[↑/↓] Scroll Logs │ [q] Quit")

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		eventBox,
		memoryBox,
		footer,
	)
}

func StartTUI(targetPid uint32) error {
	p := tea.NewProgram(
		New(targetPid),
		tea.WithAltScreen(),
		tea.WithMouseCellMotion(),
	)

	_, err := p.Run()
	return err
}

func (m *Model) updateLog(events []*tracer.ParsedEvent) {
	if len(events) == 0 {
		return
	}

	// The RingBuff emits events newest-first (index 0 is newest).
	// We need to find the oldest *unseen* event so we can process chronologically.
	oldestNewIdx := -1
	for i := 0; i < len(events); i++ {
		if events[i] == nil || events[i].Timestamp <= m.lastTimestamp {
			break
		}
		oldestNewIdx = i
	}

	// No new events found
	if oldestNewIdx == -1 {
		return
	}

	// Append in chronological order (oldest to newest)
	for i := oldestNewIdx; i >= 0; i-- {
		m.eventLog = append(m.eventLog, formatEvent(events[i]))
	}

	m.lastTimestamp = events[0].Timestamp

	// Constrain the buffer using high-performance slice shifting.
	// This reuses the backing array and avoids constant Garbage Collector pressure.
	const maxLogSize = 500
	if len(m.eventLog) > maxLogSize {
		excess := len(m.eventLog) - maxLogSize

		// Shift elements to the left
		copy(m.eventLog, m.eventLog[excess:])

		// Clear trailing elements to prevent memory leaks (optional but good practice)
		for i := maxLogSize; i < len(m.eventLog); i++ {
			m.eventLog[i] = ""
		}

		// Re-slice to the max size
		m.eventLog = m.eventLog[:maxLogSize]
	}

	m.viewport.SetContent(strings.Join(m.eventLog, "\n"))
	m.viewport.GotoBottom()
}

func formatEvent(e *tracer.ParsedEvent) string {
	comm := tracer.CleanString(e.Comm)
	ts := e.Timestamp

	switch e.Kind {
	case "openat":
		return fmt.Sprintf("%d | PID: %5d | [openat]  | Comm: %-10s | Path: %s", ts, e.PID, comm, tracer.MakeFilename(e))
	case "mmap", "munmap", "brk":
		return fmt.Sprintf("%d | PID: %5d | [%-7s] | Comm: %-10s | Addr: %x | Size: %s",
			ts, e.PID, e.Kind, comm, e.RawAddr, humanize.Bytes(uint64(e.RawSize)))
	case "connect":
		addr, port := tracer.ParseRawAddr(e)
		return fmt.Sprintf("%d | PID: %5d | [connect] | Comm: %-10s | Addr: %s:%d", ts, e.PID, comm, addr, port)
	case "exit":
		return fmt.Sprintf("%d | PID: %5d | [exit]    | Comm: %-10s", ts, e.PID, comm)
	default:
		return fmt.Sprintf("%d | PID: %5d | [unknown] | Comm: %-10s", ts, e.PID, comm)
	}
}

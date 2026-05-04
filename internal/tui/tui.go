package tui

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	baseBorder = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("240"))

	headerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("86")). // Cyan-ish
			Bold(true).
			Padding(0, 1)

	boxTitleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("205")). // Pink-ish
			Bold(true).
			MarginBottom(1)

	footerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241")). // Gray
			Padding(0, 1)
)

// Model holds the state of our TUI
type Model struct {
	width  int
	height int

	// We will store actual data here later (e.g., targetPid, memory bytes, etc.)
	targetPid uint32
}

func New(targetPid uint32) Model {
	return Model{
		targetPid: targetPid,
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m Model) View() string {
	if m.width == 0 {
		return "Initializing..."
	}

	headerText := fmt.Sprintf("MUON │ Target PID: %d │ Buffer Drops: 0", m.targetPid)
	header := headerStyle.Render(headerText)

	availableWidth := m.width - 4
	availableHeight := m.height - 12

	eventBox := baseBorder.
		Width(availableWidth).
		Height(availableHeight).
		Render(
			boxTitleStyle.Render("▼ EVENT STREAM (Tail)") + "\n" +
				"TIME      TYPE   DETAILS\n" +
				"────      ────   ───────\n" +
				"(Stream disabled for prototype...)",
		)

	memoryBox := baseBorder.
		Width(availableWidth + 2). // Spans the full width
		Render(
			boxTitleStyle.Render("▼ MEMORY TRACKER (Active Allocations)") + "\n" +
				"Total Active: 0 MB │ Peak: 0 MB │ Leaked (Unfreed): 0 B\n" +
				"[░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 0%",
		)

	footer := footerStyle.Render("[↑/↓] Navigate │ [q] Quit")

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
		tea.WithAltScreen(),       // Uses the alternate screen buffer (like vim/htop)
		tea.WithMouseCellMotion(), // Enables mouse support later if needed
	)

	_, err := p.Run()
	return err
}

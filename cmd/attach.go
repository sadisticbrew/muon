package cmd

import (
	"errors"
	"muon/internal/tracer"
	"muon/internal/tui"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
)

var targetPid uint32
var deepTrace bool = false

var attachCmd = &cobra.Command{
	Use:   "attach",
	Short: "Attach Muon to a specific process",
	RunE: func(cmd *cobra.Command, args []string) error {
		if targetPid == 0 {
			return errors.New("Target pid is required")
		}
		p := tea.NewProgram(
			tui.New(targetPid),
			tea.WithAltScreen(), // Uses the alternate screen buffer (like vim/htop)
			tea.WithMouseCellMotion(),
		)
		if deepTrace {
			return errors.New("--allocations (deep trace) is not implemented yet")
		}
		go tracer.Monitor(targetPid, p)

		_, err := p.Run()
		if err != nil {
			return err
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(attachCmd)
	attachCmd.Flags().Uint32VarP(&targetPid, "target_pid", "p", 0, "target process id")
	attachCmd.MarkFlagRequired("target_pid")
	attachCmd.Flags().BoolVar(&deepTrace, "allocations", false, "Enable deep trace mode")
}

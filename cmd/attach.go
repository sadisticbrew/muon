package cmd

import (
	"errors"
	"muon/internal/tracer"
	"muon/internal/tui"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
)

var targetPid uint32

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
		go tracer.Monitor(targetPid)

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
}

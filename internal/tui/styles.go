package tui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

var (
	promptStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("212")).Bold(true)
	countStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	subtleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	dimStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	cursorStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("212")).Bold(true)
	labelStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	activeStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("231")).Bold(true)
	runningStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("114"))
	stoppedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
)

func pad(s string, w int) string {
	gap := w - lipgloss.Width(s)
	if gap <= 0 {
		return s
	}
	return s + strings.Repeat(" ", gap)
}

func truncate(s string, n int) string {
	if lipgloss.Width(s) <= n {
		return s
	}
	if n <= 1 {
		return string([]rune(s)[:n])
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

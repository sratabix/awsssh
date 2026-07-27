package tui

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/sahilm/fuzzy"
	"github.com/sratabix/awsssh/internal/awsx"
)

type instanceModel struct {
	instances []awsx.Instance
	filter    textinput.Model
	filtered  []int
	cursor    int
	width     int
	height    int
	chosen    *awsx.Instance
}

func newInstanceModel(instances []awsx.Instance) instanceModel {
	ti := textinput.New()
	ti.Prompt = promptStyle.Render("> ")
	ti.Placeholder = ""
	ti.Focus()

	m := instanceModel{instances: instances, filter: ti}
	m.applyFilter()
	return m
}

func (m *instanceModel) applyFilter() {
	q := strings.TrimSpace(m.filter.Value())
	if q == "" {
		m.filtered = m.filtered[:0]
		for i := range m.instances {
			m.filtered = append(m.filtered, i)
		}
	} else {
		haystack := make([]string, len(m.instances))
		for i, inst := range m.instances {
			haystack[i] = instanceSearchable(inst)
		}
		matches := fuzzy.Find(q, haystack)
		m.filtered = m.filtered[:0]
		for _, match := range matches {
			m.filtered = append(m.filtered, match.Index)
		}
	}
	if m.cursor >= len(m.filtered) {
		m.cursor = len(m.filtered) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

func instanceSearchable(i awsx.Instance) string {
	return strings.Join([]string{i.Name, i.InstanceID, i.PrivateIP, i.PublicIP, i.State, i.InstanceType}, " ")
}

func (m instanceModel) Init() tea.Cmd { return textinput.Blink }

func (m instanceModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case tea.KeyPressMsg:
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "enter":
			if len(m.filtered) > 0 {
				inst := m.instances[m.filtered[m.cursor]]
				m.chosen = &inst
			}
			return m, tea.Quit
		case "up":
			if m.cursor > 0 {
				m.cursor--
			}
			return m, nil
		case "down":
			if m.cursor < len(m.filtered)-1 {
				m.cursor++
			}
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	m.applyFilter()
	return m, cmd
}

func (m instanceModel) View() tea.View {
	v := tea.NewView(m.content())
	v.AltScreen = true
	return v
}

func (m instanceModel) content() string {
	rows := m.height - 2
	if rows < 1 {
		rows = 1
	}

	count := countStyle.Render(fmt.Sprintf("  %d/%d", len(m.filtered), len(m.instances)))

	return strings.Join([]string{m.filter.View(), count, m.renderList(rows)}, "\n")
}

func (m instanceModel) renderList(rows int) string {
	if len(m.filtered) == 0 {
		return dimStyle.Render("  no matching instances")
	}

	start := 0
	if m.cursor >= rows {
		start = m.cursor - rows + 1
	}
	end := start + rows
	if end > len(m.filtered) {
		end = len(m.filtered)
	}

	nameW := 0
	for _, idx := range m.filtered {
		if w := lipgloss.Width(displayName(m.instances[idx])); w > nameW {
			nameW = w
		}
	}
	if maxW := m.width / 2; maxW > 0 && nameW > maxW {
		nameW = maxW
	}

	var b strings.Builder
	for i := start; i < end; i++ {
		inst := m.instances[m.filtered[i]]
		name := pad(truncate(displayName(inst), nameW), nameW)

		if i == m.cursor {
			b.WriteString(cursorStyle.Render("> ") + activeStyle.Render(name))
		} else {
			b.WriteString("  " + labelStyle.Render(name))
		}
		fmt.Fprintf(&b, "  %s  %s", subtleStyle.Render(inst.InstanceID), stateLabel(inst.State))

		if i < end-1 {
			b.WriteString("\n")
		}
	}
	return b.String()
}

func displayName(i awsx.Instance) string {
	if i.Name == "" {
		return "(no name)"
	}
	return i.Name
}

func stateLabel(state string) string {
	switch state {
	case "running":
		return runningStyle.Render(state)
	case "stopped", "stopping", "terminated", "shutting-down":
		return stoppedStyle.Render(state)
	default:
		return dimStyle.Render(state)
	}
}

func SelectInstance(instances []awsx.Instance) (*awsx.Instance, error) {
	p := tea.NewProgram(newInstanceModel(instances))
	res, err := p.Run()
	if err != nil {
		return nil, err
	}
	final, ok := res.(instanceModel)
	if !ok {
		return nil, fmt.Errorf("unexpected final model %T", res)
	}
	return final.chosen, nil
}

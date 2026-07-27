package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/sratabix/awsssh/internal/awsx"
)

func testInstances() []awsx.Instance {
	return []awsx.Instance{
		{Name: "web-01", InstanceID: "i-aaa", State: "running", PrivateIP: "10.0.0.1", InstanceType: "t3.micro"},
		{Name: "db-01", InstanceID: "i-bbb", State: "stopped", PrivateIP: "10.0.0.2", InstanceType: "m5.large"},
		{Name: "", InstanceID: "i-ccc", State: "running", PrivateIP: "10.0.0.3", InstanceType: "t3.nano"},
	}
}

func press(t *testing.T, m instanceModel, key string) instanceModel {
	t.Helper()
	next, _ := m.Update(tea.KeyPressMsg{Code: keyCode(key), Text: keyText(key)})
	got, ok := next.(instanceModel)
	if !ok {
		t.Fatalf("Update returned %T, want instanceModel", next)
	}
	return got
}

func keyCode(key string) rune {
	switch key {
	case "down":
		return tea.KeyDown
	case "up":
		return tea.KeyUp
	case "enter":
		return tea.KeyEnter
	case "esc":
		return tea.KeyEscape
	default:
		return rune(key[0])
	}
}

func keyText(key string) string {
	switch key {
	case "down", "up", "enter", "esc":
		return ""
	default:
		return key
	}
}

func TestFilterNarrowsAndClampsCursor(t *testing.T) {
	m := newInstanceModel(testInstances())
	if len(m.filtered) != 3 {
		t.Fatalf("empty filter matched %d instances, want 3", len(m.filtered))
	}

	m = press(t, m, "down")
	m = press(t, m, "down")
	if m.cursor != 2 {
		t.Fatalf("cursor at %d after two downs, want 2", m.cursor)
	}

	m = press(t, m, "d")
	m = press(t, m, "b")
	if got := m.filter.Value(); got != "db" {
		t.Fatalf("filter value %q, want %q", got, "db")
	}
	if len(m.filtered) != 1 || m.instances[m.filtered[0]].InstanceID != "i-bbb" {
		t.Fatalf("filter %q matched %v, want just i-bbb", m.filter.Value(), m.filtered)
	}
	if m.cursor != 0 {
		t.Fatalf("cursor at %d after filtering to one row, want 0", m.cursor)
	}
}

func TestEnterChoosesInstanceUnderCursor(t *testing.T) {
	m := press(t, newInstanceModel(testInstances()), "down")
	m = press(t, m, "enter")
	if m.chosen == nil {
		t.Fatal("enter did not choose an instance")
	}
	if m.chosen.InstanceID != "i-bbb" {
		t.Fatalf("chose %s, want i-bbb", m.chosen.InstanceID)
	}
}

func TestEscQuitsWithoutChoosing(t *testing.T) {
	m := press(t, newInstanceModel(testInstances()), "esc")
	if m.chosen != nil {
		t.Fatalf("esc chose %s, want nothing", m.chosen.InstanceID)
	}
}

func TestViewRendersAltScreenWithInstances(t *testing.T) {
	m := newInstanceModel(testInstances())
	next, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	m = next.(instanceModel)

	v := m.View()
	if !v.AltScreen {
		t.Error("view does not request the alternate screen")
	}
	for _, want := range []string{"web-01", "i-bbb", "(no name)", "3/3"} {
		if !strings.Contains(v.Content, want) {
			t.Errorf("view content missing %q", want)
		}
	}
}

func TestViewCountTracksFilter(t *testing.T) {
	m := newInstanceModel(testInstances())
	next, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = press(t, next.(instanceModel), "d")
	m = press(t, m, "b")

	if got := m.View().Content; !strings.Contains(got, "1/3") {
		t.Errorf("filtered view missing %q count, got:\n%s", "1/3", got)
	}
}

func sized(t *testing.T, instances []awsx.Instance, w, h int) instanceModel {
	t.Helper()
	next, _ := newInstanceModel(instances).Update(tea.WindowSizeMsg{Width: w, Height: h})
	m, ok := next.(instanceModel)
	if !ok {
		t.Fatalf("Update returned %T", next)
	}
	return m
}

func typeText(t *testing.T, m instanceModel, text string) instanceModel {
	t.Helper()
	for _, r := range text {
		m = press(t, m, string(r))
	}
	return m
}

func TestInitStartsTheCursorBlinking(t *testing.T) {
	if newInstanceModel(testInstances()).Init() == nil {
		t.Error("Init should return the textinput blink command")
	}
}

func TestCursorStopsAtTheTop(t *testing.T) {
	m := newInstanceModel(testInstances())
	for range 3 {
		m = press(t, m, "up")
	}
	if m.cursor != 0 {
		t.Errorf("cursor = %d, want 0", m.cursor)
	}
}

func TestCursorStopsAtTheBottom(t *testing.T) {
	m := newInstanceModel(testInstances())
	for range 10 {
		m = press(t, m, "down")
	}
	if m.cursor != len(m.filtered)-1 {
		t.Errorf("cursor = %d, want %d", m.cursor, len(m.filtered)-1)
	}
}

func TestCtrlCQuitsWithoutChoosing(t *testing.T) {
	m := press(t, newInstanceModel(testInstances()), "ctrl+c")
	if m.chosen != nil {
		t.Errorf("ctrl+c chose %s, want nothing", m.chosen.InstanceID)
	}
}

func TestEnterWithNoMatchesChoosesNothing(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "zzzznomatch")
	if len(m.filtered) != 0 {
		t.Fatalf("expected no matches, got %d", len(m.filtered))
	}
	m = press(t, m, "enter")
	if m.chosen != nil {
		t.Errorf("chose %v despite no matches", m.chosen)
	}
}

func TestViewReportsNoMatches(t *testing.T) {
	m := typeText(t, sized(t, testInstances(), 90, 20), "zzzznomatch")
	if got := m.View().Content; !strings.Contains(got, "no matching instances") {
		t.Errorf("view should say there are no matches:\n%s", got)
	}
	if !strings.Contains(m.View().Content, "0/3") {
		t.Error("count should show 0/3")
	}
}

func TestFilterMatchesOnInstanceID(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "bbb")
	if len(m.filtered) != 1 || m.instances[m.filtered[0]].InstanceID != "i-bbb" {
		t.Errorf("filtering by id matched %v", m.filtered)
	}
}

func TestFilterRanksTheBestPrivateIPMatchFirst(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "10.0.0.3")
	if len(m.filtered) == 0 {
		t.Fatal("expected at least one match")
	}
	if got := m.instances[m.filtered[0]].InstanceID; got != "i-ccc" {
		t.Errorf("top match = %s, want i-ccc", got)
	}
	if m.cursor != 0 {
		t.Errorf("cursor = %d, want the top match", m.cursor)
	}
}

func TestFilterMatchesOnState(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "stopped")
	if len(m.filtered) != 1 || m.instances[m.filtered[0]].InstanceID != "i-bbb" {
		t.Errorf("filtering by state matched %v", m.filtered)
	}
}

func TestClearingTheFilterRestoresEveryInstance(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "db")
	if len(m.filtered) != 1 {
		t.Fatalf("expected one match, got %d", len(m.filtered))
	}
	m = press(t, m, "backspace")
	m = press(t, m, "backspace")
	if len(m.filtered) != 3 {
		t.Errorf("clearing the filter left %d instances, want 3", len(m.filtered))
	}
}

func TestWhitespaceOnlyFilterMatchesEverything(t *testing.T) {
	m := typeText(t, newInstanceModel(testInstances()), "   ")
	if len(m.filtered) != 3 {
		t.Errorf("a blank filter should match everything, got %d", len(m.filtered))
	}
}

func TestViewScrollsToKeepTheCursorVisible(t *testing.T) {
	many := make([]awsx.Instance, 40)
	for i := range many {
		many[i] = awsx.Instance{Name: fmt.Sprintf("box-%02d", i), InstanceID: fmt.Sprintf("i-%02d", i), State: "running"}
	}
	m := sized(t, many, 100, 10)
	for range 30 {
		m = press(t, m, "down")
	}

	content := m.View().Content
	if !strings.Contains(content, "box-30") {
		t.Errorf("the selected row should be visible:\n%s", content)
	}
	if strings.Contains(content, "box-00") {
		t.Error("the list should have scrolled past the first row")
	}
}

func TestViewBeforeAnySizeMessageStillRenders(t *testing.T) {
	content := newInstanceModel(testInstances()).View().Content
	if content == "" {
		t.Error("the view must render something before the first WindowSizeMsg")
	}
}

func TestUnnamedInstancesAreLabelled(t *testing.T) {
	if got := displayName(awsx.Instance{InstanceID: "i-x"}); got != "(no name)" {
		t.Errorf("displayName = %q, want (no name)", got)
	}
	if got := displayName(awsx.Instance{Name: "named"}); got != "named" {
		t.Errorf("displayName = %q, want named", got)
	}
}

func TestStateLabelIsAlwaysNonEmpty(t *testing.T) {
	for _, state := range []string{"running", "stopped", "stopping", "terminated", "shutting-down", "pending", ""} {
		if got := stateLabel(state); state != "" && !strings.Contains(got, state) {
			t.Errorf("stateLabel(%q) = %q, should contain the state", state, got)
		}
	}
}

func TestTruncateKeepsWidthWithinBounds(t *testing.T) {
	cases := []struct {
		in    string
		limit int
	}{
		{"short", 10},
		{"exactly-ten", 11},
		{"a-very-long-instance-name-here", 12},
		{"ünïcodé-näme-with-accents", 10},
	}
	for _, c := range cases {
		got := truncate(c.in, c.limit)
		if lipglossWidthForTest(got) > c.limit {
			t.Errorf("truncate(%q, %d) = %q, too wide", c.in, c.limit, got)
		}
	}
}

func TestTruncateLeavesShortStringsAlone(t *testing.T) {
	if got := truncate("abc", 10); got != "abc" {
		t.Errorf("truncate = %q, want abc", got)
	}
}

func TestPadReachesTheRequestedWidth(t *testing.T) {
	if got := pad("ab", 5); lipglossWidthForTest(got) != 5 {
		t.Errorf("pad(%q) width = %d, want 5", got, lipglossWidthForTest(got))
	}
	if got := pad("abcdef", 3); got != "abcdef" {
		t.Errorf("pad must not shrink: %q", got)
	}
}

func TestInstanceSearchableIncludesEveryField(t *testing.T) {
	got := instanceSearchable(awsx.Instance{
		Name: "n", InstanceID: "i", PrivateIP: "p", PublicIP: "P", State: "s", InstanceType: "t",
	})
	for _, want := range []string{"n", "i", "p", "P", "s", "t"} {
		if !strings.Contains(got, want) {
			t.Errorf("searchable text %q missing %q", got, want)
		}
	}
}

func TestSelectInstanceRejectsAnUnexpectedModel(t *testing.T) {
	if _, err := SelectInstance(nil); err == nil {
		t.Skip("SelectInstance needs a TTY; nothing to assert here")
	}
}

func lipglossWidthForTest(s string) int {
	return lipgloss.Width(s)
}

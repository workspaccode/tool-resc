package usecase

import (
	"context"
	"sort"
	"sync"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Projects creates projects and lets devices join them by code.
type Projects struct {
	store Store
	now   Clock

	mu       sync.Mutex
	failures map[string][]time.Time // device id -> recent wrong codes
}

func NewProjects(store Store, now Clock) *Projects {
	return &Projects{store: store, now: now, failures: map[string][]time.Time{}}
}

// Wrong codes allowed per device in joinWindow.
const (
	maxJoinFailures = 10
	joinWindow      = 10 * time.Minute
)

type ProjectSummary struct {
	ID         string     `json:"id"`
	Code       string     `json:"code"`
	Name       string     `json:"name"`
	CreatedBy  string     `json:"createdBy"`
	CreatedAt  time.Time  `json:"createdAt"`
	Members    int        `json:"members"`
	Lists      int        `json:"lists"`
	Scans      int        `json:"scans"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
}

type MemberInfo struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Platform string    `json:"platform,omitempty"`
	Model    string    `json:"model,omitempty"`
	JoinedAt time.Time `json:"joinedAt"`
	LastSeen time.Time `json:"lastSeen"`
	Scans    int       `json:"scans"`
}

// ProjectDetail is what a member sees when opening a project.
type ProjectDetail struct {
	ProjectSummary
	MemberList []MemberInfo  `json:"memberList"`
	ListInfo   []ListSummary `json:"listInfo"`
	Recent     []domain.Scan `json:"recent"` // last scans, newest first
}

func (uc *Projects) Create(ctx context.Context, deviceID, name string) (ProjectSummary, error) {
	name, err := domain.ValidName(name)
	if err != nil {
		return ProjectSummary{}, err
	}
	code := domain.NewCode()
	uc.store.View(func(s *state.State) {
		for _, taken := s.ByCode[code]; taken; _, taken = s.ByCode[code] {
			code = domain.NewCode()
		}
	})
	id := newID()
	if _, err := uc.store.Dispatch(ctx, state.ProjectCreated{
		ProjectID: id, Code: code, Name: name, DeviceID: deviceID, At: uc.now().UTC(),
	}); err != nil {
		return ProjectSummary{}, err
	}
	return uc.summary(id, deviceID)
}

// Join adds the device to the project with this code.
func (uc *Projects) Join(ctx context.Context, deviceID, code string) (ProjectSummary, error) {
	if err := uc.checkAttempts(deviceID); err != nil {
		return ProjectSummary{}, err
	}
	var id string
	member := false
	if c := domain.NormalizeCode(code); c != "" {
		uc.store.View(func(s *state.State) {
			id = s.ByCode[c]
			if p, ok := s.Projects[id]; ok {
				member = p.IsMember(deviceID)
			}
		})
	}
	if id == "" {
		uc.fail(deviceID)
		return ProjectSummary{}, domain.ErrNotFound
	}
	if !member {
		if _, err := uc.store.Dispatch(ctx, state.ProjectJoined{ProjectID: id, DeviceID: deviceID, At: uc.now().UTC()}); err != nil {
			return ProjectSummary{}, err
		}
	}
	return uc.summary(id, deviceID)
}

func (uc *Projects) Leave(ctx context.Context, deviceID, projectID string) error {
	if err := member(uc.store, projectID, deviceID, func(*state.State, *domain.Project) {}); err != nil {
		return err
	}
	_, err := uc.store.Dispatch(ctx, state.ProjectLeft{ProjectID: projectID, DeviceID: deviceID, At: uc.now().UTC()})
	return err
}

// Mine lists the device's projects, most recently used first.
func (uc *Projects) Mine(_ context.Context, deviceID string) []ProjectSummary {
	out := []ProjectSummary{}
	uc.store.View(func(s *state.State) {
		for _, p := range s.Projects {
			if p.IsMember(deviceID) {
				out = append(out, summarize(s, p))
			}
		}
	})
	recent := func(p ProjectSummary) time.Time {
		if p.LastScanAt != nil && p.LastScanAt.After(p.CreatedAt) {
			return *p.LastScanAt
		}
		return p.CreatedAt
	}
	sort.Slice(out, func(i, j int) bool { return recent(out[i]).After(recent(out[j])) })
	return out
}

// Get returns the project with its members, lists and last scans.
func (uc *Projects) Get(_ context.Context, deviceID, projectID string, recent int) (ProjectDetail, error) {
	recent = clampLimit(recent, 20, 200)
	var out ProjectDetail
	err := member(uc.store, projectID, deviceID, func(s *state.State, p *domain.Project) {
		out.ProjectSummary = summarize(s, p)
		perDevice := map[string]int{}
		scans := s.Scans[p.ID]
		for _, sc := range scans {
			perDevice[sc.DeviceID]++
		}
		for id, joined := range p.Members {
			m := MemberInfo{ID: id, JoinedAt: joined, Scans: perDevice[id]}
			if d, ok := s.Devices[id]; ok {
				m.Name, m.Platform, m.Model, m.LastSeen = d.Name, d.Platform, d.Model, d.LastSeen
			}
			out.MemberList = append(out.MemberList, m)
		}
		sort.Slice(out.MemberList, func(i, j int) bool { return out.MemberList[i].JoinedAt.Before(out.MemberList[j].JoinedAt) })
		out.ListInfo = listSummaries(s, p)
		out.Recent = make([]domain.Scan, 0, recent)
		for i := len(scans) - 1; i >= 0 && len(out.Recent) < recent; i-- {
			out.Recent = append(out.Recent, scans[i])
		}
	})
	return out, err
}

func (uc *Projects) summary(id, deviceID string) (ProjectSummary, error) {
	var out ProjectSummary
	err := member(uc.store, id, deviceID, func(s *state.State, p *domain.Project) { out = summarize(s, p) })
	return out, err
}

func summarize(s *state.State, p *domain.Project) ProjectSummary {
	out := ProjectSummary{
		ID: p.ID, Code: p.Code, Name: p.Name, CreatedBy: p.CreatedBy, CreatedAt: p.CreatedAt,
		Members: len(p.Members), Lists: len(p.Lists),
	}
	scans := s.Scans[p.ID]
	out.Scans = len(scans)
	if n := len(scans); n > 0 {
		out.LastScanAt = timePtr(scans[n-1].ScannedAt)
	}
	return out
}

func (uc *Projects) checkAttempts(deviceID string) error {
	uc.mu.Lock()
	defer uc.mu.Unlock()
	cutoff := uc.now().Add(-joinWindow)
	recent := uc.failures[deviceID][:0]
	for _, t := range uc.failures[deviceID] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}
	uc.failures[deviceID] = recent
	if len(recent) >= maxJoinFailures {
		return domain.ErrTooManyAttempts
	}
	return nil
}

func (uc *Projects) fail(deviceID string) {
	uc.mu.Lock()
	defer uc.mu.Unlock()
	uc.failures[deviceID] = append(uc.failures[deviceID], uc.now())
}

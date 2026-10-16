package domain

import (
	"crypto/rand"
	"strings"
	"time"
)

// Project is shared by code: every device that enters the code becomes a
// member and syncs the project's lists and scans.
type Project struct {
	ID        string    `json:"id"`
	Code      string    `json:"code"` // XXXX-XXXX
	Name      string    `json:"name"`
	CreatedBy string    `json:"createdBy"`
	CreatedAt time.Time `json:"createdAt"`

	// Members: device id -> when it joined.
	Members map[string]time.Time `json:"-"`
	Lists   map[string]*List     `json:"-"`
}

func NewProject(id, code, name, deviceID string, at time.Time) *Project {
	return &Project{
		ID: id, Code: code, Name: name, CreatedBy: deviceID, CreatedAt: at,
		Members: map[string]time.Time{deviceID: at},
		Lists:   map[string]*List{},
	}
}

func (p *Project) IsMember(deviceID string) bool {
	_, ok := p.Members[deviceID]
	return ok
}

// codeAlphabet has no look-alikes (0/O, 1/I/L), so codes are easy to read
// out and type.
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

const codeLen = 8

// NewCode returns a random code like "K7F2-QX9M" (about 40 bits).
func NewCode() string {
	b := make([]byte, codeLen)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand doesn't fail on supported platforms
	}
	var s strings.Builder
	for i, v := range b {
		if i == codeLen/2 {
			s.WriteByte('-')
		}
		s.WriteByte(codeAlphabet[int(v)%len(codeAlphabet)])
	}
	return s.String()
}

// NormalizeCode accepts any case, spaces and dashes: "k7f2 qx9m" ->
// "K7F2-QX9M". Empty if it can't be a code.
func NormalizeCode(code string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(code) {
		if strings.ContainsRune(codeAlphabet, r) {
			b.WriteRune(r)
		} else if r != '-' && r != ' ' {
			return ""
		}
	}
	s := b.String()
	if len(s) != codeLen {
		return ""
	}
	return s[:codeLen/2] + "-" + s[codeLen/2:]
}

// ValidName trims a project or list name.
func ValidName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", Invalid("name is required")
	}
	return limit(name, 120), nil
}

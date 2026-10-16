// Package domain holds the business entities and rules of ToolsResc:
// devices, projects (shared by code), their lists (imported Excel sheets),
// scans, and how scans are counted. It has no dependencies on storage or
// transport.
package domain

import (
	"errors"
	"fmt"
)

var (
	// ErrNotFound is returned when an entity doesn't exist, or exists but
	// the device isn't allowed to know about it.
	ErrNotFound = errors.New("not found")

	// ErrInvalid wraps every input validation error.
	ErrInvalid = errors.New("invalid input")

	// ErrTooManyAttempts is returned after too many wrong project codes.
	ErrTooManyAttempts = errors.New("too many attempts, try again later")
)

// Invalid returns an error that matches ErrInvalid with errors.Is.
func Invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, args...))
}

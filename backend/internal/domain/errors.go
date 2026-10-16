// Package domain holds the business entities and rules of ToolsResc:
// projects (the app's component lists), their parts, scans, and how scans
// are counted. It has no dependencies on storage or transport.
package domain

import (
	"errors"
	"fmt"
)

var (
	// ErrNotFound is returned when a project or other entity doesn't exist.
	ErrNotFound = errors.New("not found")

	// ErrInvalid wraps every input validation error.
	ErrInvalid = errors.New("invalid input")
)

// Invalid returns an error that matches ErrInvalid with errors.Is.
func Invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, args...))
}

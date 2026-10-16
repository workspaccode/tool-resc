package domain

import "strings"

const maxKeyLen = 240

// MPNKey normalizes an MPN for matching, exactly like the app's mpnKey():
// uppercase, ASCII letters and digits only, so "rc0805fr 07820kl" matches
// "RC0805FR-07820KL". Empty if nothing is left.
func MPNKey(mpn string) string {
	var b strings.Builder
	b.Grow(len(mpn))
	for _, r := range strings.ToUpper(mpn) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	key := b.String()
	if len(key) > maxKeyLen {
		key = key[:maxKeyLen]
	}
	return key
}

// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package intutil

import "errors"

var (
	errMaxValInt32 = errors.New("conversion exceeds the maximum value for int32")
	errMinValInt32 = errors.New("conversion exceeds the minimum value for int32")
)

// ToInt32 converts i to an int32 and checks that the conversion is safe.
func ToInt32(i int) (int32, error) {
	n := int32(i) //nolint:gosec // The safety of the conversion is checked.

	err := errMaxValInt32
	if i < 0 {
		err = errMinValInt32
	}

	if i < 0 != (n < 0) {
		return 0, err
	}

	a := int(n)
	b := i

	if a != b {
		return 0, err
	}

	return n, nil
}

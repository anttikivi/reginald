package strutil_test

import (
	"strconv"
	"testing"

	"github.com/anttikivi/reginald/internal/strutil"
)

var tests = []struct {
	s    string
	l    int
	want string
}{
	{
		`Lorem  ipsum dolor sit amet, consectetur adipiscing elit. Quisque sodales laoreet lorem, sed pulvinar orci. Nam at odio non mauris interdum feugiat et aliquet mi. Maecenas vitae quam porttitor, facilisis ex sed, molestie lacus. Etiam rutrum lorem nisl, tempus commodo quam sagittis vel. Ut risus sem, commodo sit amet nulla vel, scelerisque efficitur ligula. Pellentesque facilisis tincidunt nunc, ut malesuada turpis iaculis a. Phasellus sed tellus faucibus, mollis augue ut, aliquam purus. Aliquam erat volutpat. Fusce viverra arcu arcu, non placerat dui varius sed. Ut porta, justo ut cursus faucibus, massa ex consectetur metus, vitae efficitur diam est quis augue. Morbi auctor turpis eu convallis commodo. Suspendisse vel sapien ut ex sagittis aliquam vel in risus. Nullam viverra magna est, non accumsan nisi tincidunt in. Nulla luctus, est a ornare convallis, ligula odio bibendum nisl, ac sagittis justo arcu a felis. Fusce mattis nisl eget bibendum imperdiet.

Duis sagittis, mi ac elementum luctus, ligula nisi blandit mi, vitae rhoncus sem est ac velit. Nullam luctus vitae quam sed aliquam. Pellentesque nec suscipit arcu. Fusce ultrices interdum ornare. Praesent nec ex in sapien laoreet viverra. Donec rutrum odio sed lorem accumsan pellentesque. Nullam nec purus ut quam viverra elementum et lacinia est. Maecenas at ex accumsan, rhoncus augue vitae, fermentum mauris. Morbi eu ante eu augue sollicitudin convallis.

Aenean eget lorem id elit euismod lobortis. Phasellus convallis feugiat ante, ut porttitor odio sodales sed. Praesent suscipit ipsum ut odio interdum tempor. Aliquam ac sem placerat, feugiat massa egestas, tincidunt tellus. Mauris auctor lorem congue tristique ornare. Morbi vel risus eu est consectetur laoreet ac eget felis. Phasellus eros mauris, posuere in ultricies sit amet, bibendum nec diam. Integer eget pharetra nisi. Suspendisse vel leo vitae urna rhoncus scelerisque eu eget augue. Cras efficitur neque sem, sed lacinia ex condimentum vitae. Proin at neque et elit eleifend sagittis. Proin malesuada lacus nisi, sit amet pulvinar quam aliquam non. Morbi interdum molestie leo et accumsan.

Donec mollis neque at sagittis bibendum. Curabitur diam purus, tincidunt vel malesuada et, molestie at leo. Aliquam ultricies imperdiet felis. Nam dignissim quam leo, vitae ornare nisl ultricies quis. Duis tincidunt eleifend bibendum. Nullam cursus scelerisque scelerisque. Ut et tempus libero. Quisque a volutpat mauris. Nulla tempor nunc vel diam sagittis bibendum.

Mauris sit amet magna nec tellus sagittis euismod. Fusce commodo semper odio, nec molestie ipsum luctus sit amet. Suspendisse porttitor molestie velit. Nullam feugiat finibus commodo. Vivamus et varius dui. Mauris venenatis tortor sapien, non cursus libero tempus vitae. Integer quis orci porttitor, iaculis risus ut, aliquet ligula. Nam vitae nibh et ligula imperdiet ultrices quis sed neque. Vestibulum a nisi a leo posuere rutrum. Fusce pulvinar iaculis nisl eget venenatis. Vivamus lacinia vitae purus id porta. Nullam et orci mauris. Sed dictum metus arcu, eu convallis nunc tincidunt fringilla. Phasellus sollicitudin, ligula ac luctus mollis, lorem nisl ultricies purus, convallis lacinia mi mi eget tellus.`,
		80,
		`Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque sodales laoreet
lorem, sed pulvinar orci. Nam at odio non mauris interdum feugiat et aliquet mi.
Maecenas vitae quam porttitor, facilisis ex sed, molestie lacus. Etiam rutrum
lorem nisl, tempus commodo quam sagittis vel. Ut risus sem, commodo sit amet
nulla vel, scelerisque efficitur ligula. Pellentesque facilisis tincidunt nunc,
ut malesuada turpis iaculis a. Phasellus sed tellus faucibus, mollis augue ut,
aliquam purus. Aliquam erat volutpat. Fusce viverra arcu arcu, non placerat dui
varius sed. Ut porta, justo ut cursus faucibus, massa ex consectetur metus,
vitae efficitur diam est quis augue. Morbi auctor turpis eu convallis commodo.
Suspendisse vel sapien ut ex sagittis aliquam vel in risus. Nullam viverra magna
est, non accumsan nisi tincidunt in. Nulla luctus, est a ornare convallis,
ligula odio bibendum nisl, ac sagittis justo arcu a felis. Fusce mattis nisl
eget bibendum imperdiet.

Duis sagittis, mi ac elementum luctus, ligula nisi blandit mi, vitae rhoncus sem
est ac velit. Nullam luctus vitae quam sed aliquam. Pellentesque nec suscipit
arcu. Fusce ultrices interdum ornare. Praesent nec ex in sapien laoreet viverra.
Donec rutrum odio sed lorem accumsan pellentesque. Nullam nec purus ut quam
viverra elementum et lacinia est. Maecenas at ex accumsan, rhoncus augue vitae,
fermentum mauris. Morbi eu ante eu augue sollicitudin convallis.

Aenean eget lorem id elit euismod lobortis. Phasellus convallis feugiat ante, ut
porttitor odio sodales sed. Praesent suscipit ipsum ut odio interdum tempor.
Aliquam ac sem placerat, feugiat massa egestas, tincidunt tellus. Mauris auctor
lorem congue tristique ornare. Morbi vel risus eu est consectetur laoreet ac
eget felis. Phasellus eros mauris, posuere in ultricies sit amet, bibendum nec
diam. Integer eget pharetra nisi. Suspendisse vel leo vitae urna rhoncus
scelerisque eu eget augue. Cras efficitur neque sem, sed lacinia ex condimentum
vitae. Proin at neque et elit eleifend sagittis. Proin malesuada lacus nisi, sit
amet pulvinar quam aliquam non. Morbi interdum molestie leo et accumsan.

Donec mollis neque at sagittis bibendum. Curabitur diam purus, tincidunt vel
malesuada et, molestie at leo. Aliquam ultricies imperdiet felis. Nam dignissim
quam leo, vitae ornare nisl ultricies quis. Duis tincidunt eleifend bibendum.
Nullam cursus scelerisque scelerisque. Ut et tempus libero. Quisque a volutpat
mauris. Nulla tempor nunc vel diam sagittis bibendum.

Mauris sit amet magna nec tellus sagittis euismod. Fusce commodo semper odio,
nec molestie ipsum luctus sit amet. Suspendisse porttitor molestie velit. Nullam
feugiat finibus commodo. Vivamus et varius dui. Mauris venenatis tortor sapien,
non cursus libero tempus vitae. Integer quis orci porttitor, iaculis risus ut,
aliquet ligula. Nam vitae nibh et ligula imperdiet ultrices quis sed neque.
Vestibulum a nisi a leo posuere rutrum. Fusce pulvinar iaculis nisl eget
venenatis. Vivamus lacinia vitae purus id porta. Nullam et orci mauris. Sed
dictum metus arcu, eu convallis nunc tincidunt fringilla. Phasellus
sollicitudin, ligula ac luctus mollis, lorem nisl ultricies purus, convallis
lacinia mi mi eget tellus.`,
	},

	{
		`Lorem  ipsum dolor sit amet, consectetur adipiscing elit. Quisque sodales laoreet lorem, sed pulvinar orci. Nam at odio non mauris interdum feugiat et aliquet mi. Maecenas vitae quam porttitor, facilisis ex sed, molestie lacus. Etiam rutrum lorem nisl, tempus commodo quam sagittis vel. Ut risus sem, commodo sit amet nulla vel, scelerisque efficitur ligula. Pellentesque facilisis tincidunt nunc, ut malesuada turpis iaculis a. Phasellus sed tellus faucibus, mollis augue ut, aliquam purus. Aliquam erat volutpat. Fusce viverra arcu arcu, non placerat dui varius sed. Ut porta, justo ut cursus faucibus, massa ex consectetur metus, vitae efficitur diam est quis augue. Morbi auctor turpis eu convallis commodo. Suspendisse vel sapien ut ex sagittis aliquam vel in risus. Nullam viverra magna est, non accumsan nisi tincidunt in. Nulla luctus, est a ornare convallis, ligula odio bibendum nisl, ac sagittis justo arcu a felis. Fusce mattis nisl eget bibendum imperdiet.

Duis sagittis, mi ac elementum luctus, ligula nisi blandit mi, vitae rhoncus sem est ac velit. Nullam luctus vitae quam sed aliquam. Pellentesque nec suscipit arcu. Fusce ultrices interdum ornare. Praesent nec ex in sapien laoreet viverra. Donec rutrum odio sed lorem accumsan pellentesque. Nullam nec purus ut quam viverra elementum et lacinia est. Maecenas at ex accumsan, rhoncus augue vitae, fermentum mauris. Morbi eu ante eu augue sollicitudin convallis.

Aenean eget lorem id elit euismod lobortis. Phasellus convallis feugiat ante, ut porttitor odio sodales sed. Praesent suscipit ipsum ut odio interdum tempor. Aliquam ac sem placerat, feugiat massa egestas, tincidunt tellus. Mauris auctor lorem congue tristique ornare. Morbi vel risus eu est consectetur laoreet ac eget felis. Phasellus eros mauris, posuere in ultricies sit amet, bibendum nec diam. Integer eget pharetra nisi. Suspendisse vel leo vitae urna rhoncus scelerisque eu eget augue. Cras efficitur neque sem, sed lacinia ex condimentum vitae. Proin at neque et elit eleifend sagittis. Proin malesuada lacus nisi, sit amet pulvinar quam aliquam non. Morbi interdum molestie leo et accumsan.

Donec mollis neque at sagittis bibendum. Curabitur diam purus, tincidunt vel malesuada et, molestie at leo. Aliquam ultricies imperdiet felis. Nam dignissim quam leo, vitae ornare nisl ultricies quis. Duis tincidunt eleifend bibendum. Nullam cursus scelerisque scelerisque. Ut et tempus libero. Quisque a volutpat mauris. Nulla tempor nunc vel diam sagittis bibendum.

Mauris sit amet magna nec tellus sagittis euismod. Fusce commodo semper odio, nec molestie ipsum luctus sit amet. Suspendisse porttitor molestie velit. Nullam feugiat finibus commodo. Vivamus et varius dui. Mauris venenatis tortor sapien, non cursus libero tempus vitae. Integer quis orci porttitor, iaculis risus ut, aliquet ligula. Nam vitae nibh et ligula imperdiet ultrices quis sed neque. Vestibulum a nisi a leo posuere rutrum. Fusce pulvinar iaculis nisl eget venenatis. Vivamus lacinia vitae purus id porta. Nullam et orci mauris. Sed dictum metus arcu, eu convallis nunc tincidunt fringilla. Phasellus sollicitudin, ligula ac luctus mollis, lorem nisl ultricies purus, convallis lacinia mi mi eget tellus.`,
		80,
		`Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque sodales laoreet
lorem, sed pulvinar orci. Nam at odio non mauris interdum feugiat et aliquet mi.
Maecenas vitae quam porttitor, facilisis ex sed, molestie lacus. Etiam rutrum
lorem nisl, tempus commodo quam sagittis vel. Ut risus sem, commodo sit amet
nulla vel, scelerisque efficitur ligula. Pellentesque facilisis tincidunt nunc,
ut malesuada turpis iaculis a. Phasellus sed tellus faucibus, mollis augue ut,
aliquam purus. Aliquam erat volutpat. Fusce viverra arcu arcu, non placerat dui
varius sed. Ut porta, justo ut cursus faucibus, massa ex consectetur metus,
vitae efficitur diam est quis augue. Morbi auctor turpis eu convallis commodo.
Suspendisse vel sapien ut ex sagittis aliquam vel in risus. Nullam viverra magna
est, non accumsan nisi tincidunt in. Nulla luctus, est a ornare convallis,
ligula odio bibendum nisl, ac sagittis justo arcu a felis. Fusce mattis nisl
eget bibendum imperdiet.

Duis sagittis, mi ac elementum luctus, ligula nisi blandit mi, vitae rhoncus sem
est ac velit. Nullam luctus vitae quam sed aliquam. Pellentesque nec suscipit
arcu. Fusce ultrices interdum ornare. Praesent nec ex in sapien laoreet viverra.
Donec rutrum odio sed lorem accumsan pellentesque. Nullam nec purus ut quam
viverra elementum et lacinia est. Maecenas at ex accumsan, rhoncus augue vitae,
fermentum mauris. Morbi eu ante eu augue sollicitudin convallis.

Aenean eget lorem id elit euismod lobortis. Phasellus convallis feugiat ante, ut
porttitor odio sodales sed. Praesent suscipit ipsum ut odio interdum tempor.
Aliquam ac sem placerat, feugiat massa egestas, tincidunt tellus. Mauris auctor
lorem congue tristique ornare. Morbi vel risus eu est consectetur laoreet ac
eget felis. Phasellus eros mauris, posuere in ultricies sit amet, bibendum nec
diam. Integer eget pharetra nisi. Suspendisse vel leo vitae urna rhoncus
scelerisque eu eget augue. Cras efficitur neque sem, sed lacinia ex condimentum
vitae. Proin at neque et elit eleifend sagittis. Proin malesuada lacus nisi, sit
amet pulvinar quam aliquam non. Morbi interdum molestie leo et accumsan.

Donec mollis neque at sagittis bibendum. Curabitur diam purus, tincidunt vel
malesuada et, molestie at leo. Aliquam ultricies imperdiet felis. Nam dignissim
quam leo, vitae ornare nisl ultricies quis. Duis tincidunt eleifend bibendum.
Nullam cursus scelerisque scelerisque. Ut et tempus libero. Quisque a volutpat
mauris. Nulla tempor nunc vel diam sagittis bibendum.

Mauris sit amet magna nec tellus sagittis euismod. Fusce commodo semper odio,
nec molestie ipsum luctus sit amet. Suspendisse porttitor molestie velit. Nullam
feugiat finibus commodo. Vivamus et varius dui. Mauris venenatis tortor sapien,
non cursus libero tempus vitae. Integer quis orci porttitor, iaculis risus ut,
aliquet ligula. Nam vitae nibh et ligula imperdiet ultrices quis sed neque.
Vestibulum a nisi a leo posuere rutrum. Fusce pulvinar iaculis nisl eget
venenatis. Vivamus lacinia vitae purus id porta. Nullam et orci mauris. Sed
dictum metus arcu, eu convallis nunc tincidunt fringilla. Phasellus
sollicitudin, ligula ac luctus mollis, lorem nisl ultricies purus, convallis
lacinia mi mi eget tellus.`,
	},

	{
		`Proin et risus lacinia, venenatis nisl ac, efficitur magna. Maecenas tempor mollis eros sit amet congue. Suspendisse non orci nec nisi fringilla vehicula. Ut sit amet felis a sapien dictum tincidunt vitae vel libero. Suspendisse elit risus, porta quis lectus vel, lobortis bibendum ligula.

Fusce venenatis felis viverra, interdum dolor vel, fermentum velit. Integer ex nulla, varius sed sem non, congue elementum metus. Vestibulum sollicitudin posuere augue id volutpat.`,
		10,
		`Proin et
risus
lacinia,
venenatis
nisl ac,
efficitur
magna.
Maecenas
tempor
mollis
eros sit
amet
congue.
Suspendisse
non orci
nec nisi
fringilla
vehicula.
Ut sit
amet felis
a sapien
dictum
tincidunt
vitae vel
libero.
Suspendisse
elit
risus,
porta quis
lectus
vel,
lobortis
bibendum
ligula.

Fusce
venenatis
felis
viverra,
interdum
dolor vel,
fermentum
velit.
Integer ex
nulla,
varius sed
sem non,
congue
elementum
metus.
Vestibulum
sollicitudin
posuere
augue id
volutpat.`,
	},

	{
		`Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`,
		80,
		`Bootstrap clones the specified dotfiles directory and runs the initial
installation.

Bootstrapping should only be run in an environment that is not set up. The
command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`,
	},

	{
		`Bootstrap clones the specified dotfiles directory and runs the initial installation.`,
		120,
		`Bootstrap clones the specified dotfiles directory and runs the initial installation.`,
	},

	{
		`Bootstrap clones the specified dotfiles directory and runs the initial installation.`,
		1,
		`Bootstrap
clones
the
specified
dotfiles
directory
and
runs
the
initial
installation.`,
	},

	{
		"",
		10,
		"",
	},
}

func TestCap(t *testing.T) {
	t.Parallel()

	for i, tt := range tests {
		t.Run(strconv.Itoa(i), func(t *testing.T) {
			t.Parallel()

			got := strutil.Cap(tt.s, tt.l)

			if got != tt.want {
				t.Errorf("Cap(`%s`, %d) = `%v`, want `%v`", tt.s, tt.l, got, tt.want)
			}
		})
	}
}

func BenchmarkCap(b *testing.B) {
	for i, tt := range tests {
		b.Run(strconv.Itoa(i), func(b *testing.B) {
			for range b.N {
				_ = strutil.Cap(tt.s, tt.l)
			}
		})
	}
}

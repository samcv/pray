class Pray::Output;

subset PInt of Int where * > 0;
subset NNInt of Int where * >= 0;

has Str $.file;
has PInt $.width;
has PInt $.height;
has Bool $.quiet = False;
has Bool $.preview = !$!quiet;
has Bool $.sync = True;
has $.preview-width = 80;
has $.preview-dither = 0;

sub preview_scale ($v, $reduction) {
    ($v div $reduction) + !($v %% $reduction);
}

has $!buffer = Buf[uint8].new();
has PInt $!preview-scale-w = preview_scale($!width, $!preview-width - 2);
has PInt $!preview-scale-h = $!preview-scale-w * 2;
has $.preview-every = $!width * $!preview-scale-h;
has PInt $!preview-scale-area = $!preview-scale-w * $!preview-scale-h;
has PInt $!preview-w = preview_scale($!width, $!preview-scale-w);
has PInt $!preview-h = preview_scale($!height, $!preview-scale-h);
has Str $!preview-string =
    "┌{'─' x $!preview-w}┐\n" ~
    "│{'.' x $!preview-w}│\n" x $!preview-h ~
    "└{'─' x $!preview-w}┘";
has @!dirty;
has $!supply = $!sync ?? Any !! Supply.new;
has $!promise;
has $!next-preview = 0;
has $!begin-time = now;
has $.count = 0;
has $.finished = False;
has $!preview-buffer = Buf[uint32].new();
has @!preview-chars = ' ', '░', '▒', '▓', '█';
has $!preview-shades = @!preview-chars - 1;
has &!clear = $*DISTRO.is-win ?? -> {shell 'cls'} !! -> {run 'clear'};

method new (|) {
    callsame!init;
}

method !init () {

    # this workaround prevents substr-rw from causing string corruption later
    # TODO reduce & report
    # perl6 -MPray::Output -e 'my $o = Pray::Output.new(:width(64), :height(64)); sleep 2; $o.set(56, 56, 1, 1, 1); $o.finish;'
    substr-rw($!preview-string, $!preview-w+4, 0) = '';

    self.preview: :force if $!preview;
    unless $!sync {
        $!supply.act: -> $v { self!set(|$v) };
        $!promise = Promise.new;
        $!supply.tap: done => { $!promise.keep };
    }

    self;
}

method coord_index ($x, $y) { ($y * $!width + $x) * 3 }

method coord_preview ($x, $y) {
    $x div $!preview-scale-w,
    $y div $!preview-scale-h;
}

method coord_preview_index ($x is copy, $y is copy) {
    ($x, $y) = self.coord_preview($x, $y);
    self.preview_coord_index: $x, $y;
}

method preview_coord_index ($x, $y) {
    ($y + 1) * ($!preview-w + 3) + $x + 1;
}

method finish () {
    return True if $!finished;

    my $seconds = now - $!begin-time;

    unless $!sync {
        $!supply.done;
        $!promise.result;
    }

    if $!preview {
        self.preview: :force;
        print "\n";
    }

    unless $!quiet {
        my $time = seconds_to_time($seconds);
        printf "$!count pixels / $time = %.2f pixels/sec\n",
            $!count / $seconds;
    }

    $!finished = True;

    True;
}

method write () {
    self.finish;

    my $fh = $!file.IO.open: :w;
    $fh.print: "P3\n$!width $!height\n255\n";
    my $len = $!width * 3;
    for ^$!height -> $row {
        my $i = $row * $len;
        my $line = '';
        $line ~= "\n" if $row;
        $line ~= $!buffer[$_] ~ ' ' for $i .. $i + $len - 1;
        $fh.print: $line;
    }
    $fh.close;
}

method set (NNInt $x, NNInt $y, $r, $g, $b) {
    die "($x, $y) is outside of (0..{$!width-1}, 0..{$!height-1})"
        unless $x < $!width && $y < $!height;

    if $!sync {
        self!set($x, $y, $r, $g, $b);
    } else {
        start { $!supply.emit: [$x, $y, $r, $g, $b] };
    }

    True;
}

sub process ($_) {
    $_ <= 0 ?? 0 !!
    $_ >= 1 ?? 255 !!
    ($_ * 255).Int;
}

method !set ($x, $y, $r is copy, $g is copy, $b is copy) {
    my $i = self.coord_index($x, $y);

    $r = process $r;
    $g = process $g;
    $b = process $b;

    my $v =
        ($r - $!buffer[$i]) +
        ($g - $!buffer[$i+1]) +
        ($b - $!buffer[$i+2])
        if $!preview;

    $!buffer[$i] = $r;
    $!buffer[$i+1] = $g;
    $!buffer[$i+2] = $b;

    $!count++;

    if $!preview {
        my ($px, $py) = self.coord_preview($x,$y);
        my $i = $!preview-w * $py + $px;
        $!preview-buffer[$i] = $!preview-buffer[$i] + $v;
        @!dirty.push: [$px, $py];

        self.preview;
    }

    True;
}

method !get ($x, $y) {
    my $i = self.coord_index($x, $y);
    $!buffer[$i], $!buffer[$i+1], $!buffer[$i+2];
}

method get ($x, $y) {
    self!get($x, $y).map: */255;
}

method preview (Bool :$force = False) {
    if @!dirty >= $!preview-every or $force {
        for @!dirty.unique(:with(&infix:<eqv>)) -> [$x, $y] {
            self.update_preview($x, $y);
        }

        @!dirty = ();

        &!clear();
        print $!preview-string;
    }

    True;
}

method update_preview ($x, $y) {
    substr-rw( $!preview-string, self.preview_coord_index($x, $y), 1 ) =
        self.preview_char:
            $!preview-buffer[$!preview-w * $y + $x] / $!preview-scale-area;

    True;
}

method preview_char ($shade) {
    my @chars := @!preview-chars;
    my $shades := $!preview-shades;

    $shade >= 765 ?? @chars[*-1] !!
    $shade <= 0 ?? @chars[0] !!
    do {
        my $i = $shade * $shades / 765;
        $i += (rand - .5) * $!preview-dither if $!preview-dither;
        $i .= Int;
        $i = [max] 1, [min] $shades, $i+1;
        @chars[$i];
    };
}

my @time_units = (
    [    86400,    'day',            'dy'    ],
    [    3600,    'hour',            'hr'    ],
    [    60,        'minute',        'min'    ],
    [    1,        'second',        'sec'    ],
    [    1/1000,    'millisecond',    'ms'    ]
);

sub seconds_to_time ($seconds is copy) {

    my $return = '';
    for @time_units {
        my $last = ($_ === @time_units[*-1]);
        next unless $_[0] < $seconds || $last;
        my $value = $seconds / $_[0];
        $value = $last ?? +sprintf('%.2f', $value) !! $value.Int;
        next unless $value;
        $seconds -= $value * $_[0];
        my $plural = $value == 1 || $_[2] ~~ /'s' $/ ?? '' !! 's';
        $return ~= ' ' if $return.chars;
        $return ~= "$value $_[2]$plural";
    }

    return $return;
}



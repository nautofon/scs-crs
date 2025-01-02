#! /usr/bin/env perl

use v5.20;
use warnings;
use feature qw( postderef signatures );
no warnings qw( experimental::postderef experimental::signatures );
use lib 'cpan/lib/perl5';

use Archive::SCS::GameDir;
use Feature::Compat::Defer;
use Geo::LibProj::FFI 0.05 qw( :all );
use JSON::PP qw( decode_json );
use Math::Trig qw( pi );
use Path::Tiny 0.011 qw( path );


my $game = 'ATS';
my $scs = Archive::SCS::GameDir->new( game => $game )->mounted('def.scs');

my $format = '%.0f';
my $pair = qr/\s* \( \s* ([^,]*) \s* , \s* ([^)]*) \s* \)/x;

# Parse game projection parameters.

my $climate_sii = $scs->read_entry('def/climate.sii');
my ($map_factor_n, $map_factor_e) = $climate_sii =~ m/map_factor: $pair/x;
my ($map_offset_e, $map_offset_s) = $climate_sii =~ m/map_offset: $pair/x;
my ($lat_0,        $lon_0       ) = $climate_sii =~ m/map_origin: $pair/x;
my ($lat_1) = $climate_sii =~ m/standard_paral?lel_1: \s* (.*)/x;
my ($lat_2) = $climate_sii =~ m/standard_paral?lel_2: \s* (.*)/x;
$map_offset_e //= 0;
$map_offset_s //= 0;

my $earth_radius  = 6371007; # meters (GRS80)
my $degree_length = $earth_radius * pi / 180;
my $proj_string = <<"";
+proj=pipeline
+step +proj=unitconvert
  +xy_in=deg +xy_out=rad
+step +proj=lcc
  +lat_0=$lat_0 +lon_0=$lon_0
  +lat_1=$lat_1 +lat_2=$lat_2
  +R=$earth_radius

if ($ENV{DEBUG}) {
  say sprintf "map scale denominator: E-W %s, N-S %s",
    map { $_ * $degree_length } $map_factor_e, $map_factor_n;
  say "standard parallels: $lat_1 deg, $lat_2 deg";
  say "map_origin: lon $lon_0 deg, lat $lat_0 deg";
  say "map_offset: $map_offset_e m E, $map_offset_s m S";
  print $proj_string;
}


# Transform geographic coordinates to game coordinates.

my $geojson = decode_json( path(lc "ne_$game.geojson")->slurp_raw );

my $pj = proj_create(0, $proj_string) or die "Cannot create proj";
defer { proj_destroy($pj); }

sub transform ( $lon, $lat ) {
  my $lcc = proj_trans( $pj, PJ_FWD, proj_coord( $lon, $lat, 0, 'Inf' ) );
  my $easting  = $lcc->enu_e / $map_factor_e / $degree_length + $map_offset_e;
  my $southing = $lcc->enu_n / $map_factor_n / $degree_length + $map_offset_s;
  return [ $easting, $southing ];
  # The result is south-oriented because map_factor_n is negative.
}

my @lines;
for my $feature ( $geojson->{features}->@* ) {
  $feature->{geometry}{type} eq 'MultiLineString' or die
    sprintf 'Geometry type "%s" unsupported', $feature->{geometry}{type};

  push @lines, [ map { transform @$_ } @$_ ]
    for $feature->{geometry}{coordinates}->@*;
}


# Parse game UI map texture parameters.

my $map_data_sii = $scs->read_entry('def/map_data.sii');
my ($ui_map_center_e, $ui_map_center_s) = $map_data_sii =~ m/ui_map_center: $pair/x;
my ($ui_map_width,    $ui_map_height  ) = $map_data_sii =~ m/ui_map_size:   $pair/x;

# Calculate map texture extent (= SVG viewBox dimensions).
my $map_factor_ratio = abs $map_factor_e / $map_factor_n;
my %map_scale = ( # nominal scale denominator
  ATS  => 20,
);
# ui_map_width / ui_map_height are given in km.
my %viewbox;
$viewbox{width}  = $ui_map_width  * 1000 / $map_scale{$game};
$viewbox{height} = $ui_map_height * 1000 / $map_scale{$game} * $map_factor_ratio;
$viewbox{min_x}  = $ui_map_center_e - $viewbox{width}  / 2;
$viewbox{min_y}  = $ui_map_center_s - $viewbox{height} / 2;

# The UI map needs to be shifted south by 2 pixels (don't know why).
my %ui_map_px_size = ( # m/pixel
  width  => $viewbox{width}  / 2048,
  height => $viewbox{height} / 2048,
);
my $ui_map_transform = sprintf "translate(0 $format)", $ui_map_px_size{height} * 2;

if ($ENV{DEBUG}) {
  say "ui_map_center: $ui_map_center_e m E, $ui_map_center_s m S";
  say "ui_map_width: $ui_map_width km, ui_map_height: $ui_map_height km";
  say "map_factor_ratio: $map_factor_ratio, ui_map_transform: $ui_map_transform";
  say "SVG viewBox: ", join " ", map { $viewbox{$_} } qw( min_x min_y width height );
}


# Create SVG output file.

$_ = sprintf $format, $_ for values %viewbox;

my $svg_height = 960; # pixels
my $svg_width  = int $svg_height / $map_factor_ratio;
my $svg = <<"";
<svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink" width="${svg_width}px" height="${svg_height}px" viewBox="$viewbox{min_x} $viewbox{min_y} $viewbox{width} $viewbox{height}">
  <style>
    polyline { fill: none; stroke: red; stroke-width: 128; stroke-linejoin: round; stroke-linecap: round; }
  </style>
  <image x:href="map.png" x="$viewbox{min_x}" y="$viewbox{min_y}" width="$viewbox{width}" height="$viewbox{height}" preserveAspectRatio="none" transform="$ui_map_transform"/>

for (@lines) {
  my $points = join " ", map { sprintf "$format,$format", @$_ } @$_;
  $svg .= qq{  <polyline points="$points"/>\n};
}

$svg .= <<"";
</svg>

path(lc "ne_$game.svg")->spew_raw($svg);

exit;

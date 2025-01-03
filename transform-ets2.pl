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


my $game = 'ETS2';
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
  ETS2 => 19,
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

my $map_filename = 'map-ets2';

if ($ENV{DEBUG}) {
  say "ui_map_center: $ui_map_center_e m E, $ui_map_center_s m S";
  say "ui_map_width: $ui_map_width km, ui_map_height: $ui_map_height km";
  say "map_factor_ratio: $map_factor_ratio, ui_map_transform: $ui_map_transform";
  say "SVG viewBox: ", join " ", map { $viewbox{$_} } qw( min_x min_y width height );
}


# Create world and aux files, to enable using map.png in QGIS.

my @world_file = (
  $ui_map_px_size{width},
  0,
  0,
  -( $ui_map_px_size{height} ), # north-oriented, see remark in WKT
     $viewbox{min_x} + $ui_map_px_size{width}  * 0.5,
  -( $viewbox{min_y} + $ui_map_px_size{height} * 2.5 ),
);
path("$map_filename.pgw")->spew_raw( map { "$_\n" } @world_file );

sub wkt ($crs_name, $axis2_factor, $axis2, $scope, $remark) {
  state $wkt_tmpl = do { local $/; <DATA> };
  $wkt_tmpl =~ s/\{ (.*?) \}/ eval $1 /egrx;
}

my $game_fullname = 'Euro Truck Simulator 2';

path("$map_filename.png.aux.xml")->spew_raw(
  "<PAMDataset><SRS>",
  wkt(
    qq["$game coordinate system (2D inverted)"],
    -1,
    qq["northing (N)",north],
    qq["$game_fullname 2D game coordinates (GIS)"],
    qq["The second axis of $game coordinates is normally south-oriented. However, QGIS (as of 3.40) does not seem to support north-up visualization of a south-oriented CRS. This WKT is north-oriented to work around that."],
  ),
  "</SRS></PAMDataset>\n",
);

path(lc "wkt-$game.txt")->spew_raw( wkt(
  qq["$game coordinate system (2D)"],
  1,
  qq["southing (S)",south],
  qq["$game_fullname 2D game coordinates"],
  qq["The second axis of $game coordinates is south-oriented (values increase towards the south). This WKT is suitable for raw coordinate transformations."],
));


# Create SVG output file.

$_ = sprintf $format, $_ for values %viewbox;

my $svg_height = 960; # pixels
my $svg_width  = int $svg_height / $map_factor_ratio;
my $svg = <<"";
<svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink" width="${svg_width}px" height="${svg_height}px" viewBox="$viewbox{min_x} $viewbox{min_y} $viewbox{width} $viewbox{height}" preserveAspectRatio="none">
  <style>
    polyline { fill: none; stroke: red; stroke-width: 128; stroke-linejoin: round; stroke-linecap: round; }
  </style>
  <image x:href="$map_filename.png" x="$viewbox{min_x}" y="$viewbox{min_y}" width="$viewbox{width}" height="$viewbox{height}" preserveAspectRatio="none" transform="$ui_map_transform"/>

for (@lines) {
  my $points = join " ", map { sprintf "$format,$format", @$_ } @$_;
  $svg .= qq{  <polyline points="$points"/>\n};
}

$svg .= <<"";
</svg>

path(lc "ne_$game.svg")->spew_raw($svg);

exit;


__DATA__

DERIVEDPROJCRS[{ $crs_name },
  BASEPROJCRS["{ $game } map projection, Lambert Conformal Conic (spherical)",
    BASEGEOGCRS["Unspecified datum based upon the GRS 1980 Authalic Sphere",
      DATUM["Not specified (based on GRS 1980 Authalic Sphere)",
        ELLIPSOID["GRS 1980 Authalic Sphere",{ $earth_radius },0,
          LENGTHUNIT["metre",1,
            ID["EPSG",9001]],
          ID["EPSG",7048]]],
      PRIMEM["Greenwich",0,
        ID["EPSG",8901]],
      CS[Ellipsoidal,2],
        AXIS["geodetic latitude (Lat)",north,
          ORDER[1]],
        AXIS["geodetic longitude (Lon)",east,
          ORDER[2]],
      ANGLEUNIT["degree",0.0174532925199433,
        ID["EPSG",9102]],
      ID["EPSG",4047]],
    CONVERSION["Lambert Conformal Conic projection",
      METHOD["Lambert Conic Conformal (2SP)",
        ID["EPSG",9802]],
      PARAMETER["Latitude of false origin",{ $lat_0 },
        ANGLEUNIT["degree",0.0174532925199433],
        ID["EPSG",8821]],
      PARAMETER["Longitude of false origin",{ $lon_0 },
        ANGLEUNIT["degree",0.0174532925199433],
        ID["EPSG",8822]],
      PARAMETER["Latitude of 1st standard parallel",{ $lat_1 },
        ANGLEUNIT["degree",0.0174532925199433],
        ID["EPSG",8823]],
      PARAMETER["Latitude of 2nd standard parallel",{ $lat_2 },
        ANGLEUNIT["degree",0.0174532925199433],
        ID["EPSG",8824]],
      PARAMETER["Easting at false origin",{ $map_offset_e * $degree_length * $map_factor_e },
        LENGTHUNIT["metre",1],
        ID["EPSG",8826]],
      PARAMETER["Northing at false origin",{ $map_offset_s * $degree_length * $map_factor_n },
        LENGTHUNIT["metre",1],
        ID["EPSG",8827]]]],
  DERIVINGCONVERSION["{ $game } map scale, approx. 1:{ sprintf '%.2f', ($map_factor_e + abs $map_factor_n) * $degree_length / 2 }",
    METHOD["Affine parametric transformation",
      ID["EPSG",9624]],
    PARAMETER["A0",0,
      LENGTHUNIT["metre",1],
      ID["EPSG",8623]],
    PARAMETER["A1",{ 1 / $map_factor_e / $degree_length },
      SCALEUNIT["coefficient",1],
      ID["EPSG",8624]],
    PARAMETER["A2",0,
      SCALEUNIT["coefficient",1],
      ID["EPSG",8625]],
    PARAMETER["B0",0,
      LENGTHUNIT["metre",1],
      ID["EPSG",8639]],
    PARAMETER["B1",0,
      SCALEUNIT["coefficient",1],
      ID["EPSG",8640]],
    PARAMETER["B2",{ $axis2_factor / $map_factor_n / $degree_length },
      SCALEUNIT["coefficient",1],
      ID["EPSG",8641]],
    REMARK["The { $game } scale differs slightly between axes."]],
  CS[Cartesian,2],
    AXIS["easting (E)",east,
      ORDER[1]],
    AXIS[{ $axis2 },
      ORDER[2]],
    LENGTHUNIT["metre",1,
      ID["EPSG",9001]],
  USAGE[SCOPE[{ $scope }],
    AREA["North America"],
    BBOX[10,-140,65,-50]],
  REMARK[{ $remark }]]

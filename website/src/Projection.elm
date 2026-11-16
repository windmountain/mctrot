module Projection exposing (toMap)

{-| Places a GPS position (WGS 84 degrees) on the site's Manhattan map, in
the coordinates of `MctrotMapData.mapViewBox`.

scripts/export_map\_svg.py draws that map in three steps, which `toMap`
repeats:

1.  Project to NAD83 / New York Long Island, US survey feet (EPSG:2263): a
    Lambert Conformal Conic projection.
2.  Rotate 29° counterclockwise around Manhattan's centroid, so the street
    grid runs straight up the page (`ROTATION_DEGREES`).
3.  Negate y, as `ST_AsSVG` does: SVG's y axis points down.

NAD83 and WGS 84 differ by about a metre in Manhattan; a GPS fix is far
less precise than that. tests/ProjectionTest.elm checks that every
McDonald's lands on its dot in the map.

-}


{-| `( x, y )` in the map's SVG coordinates.
-}
toMap : { lat : Float, lon : Float } -> ( Float, Float )
toMap { lat, lon } =
    let
        ( easting, northing ) =
            projectFeet lat lon

        dx =
            easting - rotationCenter.x

        dy =
            northing - rotationCenter.y

        c =
            cos rotation

        s =
            sin rotation
    in
    ( rotationCenter.x + c * dx - s * dy
    , -(rotationCenter.y + s * dx + c * dy)
    )


{-| `ROTATION_DEGREES` in scripts/export\_map\_svg.py.
-}
rotation : Float
rotation =
    degrees 29


{-| Manhattan's centroid in EPSG:2263 feet (`ST_Centroid` of the `mcisland`
table in export\_map\_svg.py). The generated map data doesn't carry it;
this was recovered from the 46 McDonald's, which it fits to within 0.1 ft.
If the map is regenerated from different island data, re-derive it;
ProjectionTest will fail until then.
-}
rotationCenter : { x : Float, y : Float }
rotationCenter =
    { x = 993018.1, y = 222748.0 }



-- EPSG:2263: Lambert Conformal Conic (2SP) on the GRS 1980 ellipsoid.
-- Standard parallels 41°02' and 40°40', origin 40°10'N 74°W,
-- false easting 300 000 m, false northing 0. Formulas from EPSG Guidance
-- Note 7-2, section 3.1.1.


semiMajorAxis : Float
semiMajorAxis =
    6378137


eccentricity : Float
eccentricity =
    let
        flattening =
            1 / 298.257222101
    in
    sqrt (2 * flattening - flattening * flattening)


{-| One US survey foot in metres.
-}
usSurveyFoot : Float
usSurveyFoot =
    1200 / 3937


falseEasting : Float
falseEasting =
    300000


latitude1 : Float
latitude1 =
    degrees (41 + 2 / 60)


latitude2 : Float
latitude2 =
    degrees (40 + 40 / 60)


latitudeOrigin : Float
latitudeOrigin =
    degrees (40 + 10 / 60)


longitudeOrigin : Float
longitudeOrigin =
    degrees -74


m : Float -> Float
m phi =
    cos phi / sqrt (1 - (eccentricity * sin phi) ^ 2)


t : Float -> Float
t phi =
    let
        es =
            eccentricity * sin phi
    in
    tan (pi / 4 - phi / 2) / (((1 - es) / (1 + es)) ^ (eccentricity / 2))


n : Float
n =
    (ln (m latitude1) - ln (m latitude2)) / (ln (t latitude1) - ln (t latitude2))


rho : Float -> Float
rho phi =
    semiMajorAxis * (m latitude1 / (n * t latitude1 ^ n)) * t phi ^ n


ln : Float -> Float
ln =
    logBase e


{-| ( easting, northing ) in US survey feet.
-}
projectFeet : Float -> Float -> ( Float, Float )
projectFeet lat lon =
    let
        theta =
            n * (degrees lon - longitudeOrigin)

        r =
            rho (degrees lat)
    in
    ( (falseEasting + r * sin theta) / usSurveyFoot
    , (rho latitudeOrigin - r * cos theta) / usSurveyFoot
    )

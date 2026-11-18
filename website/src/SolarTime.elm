module SolarTime exposing (Times, describe)

{-| The time of day by the sun, in words: "Nautical twilight", "Civil
twilight. 12 minutes before sunrise", "3 hours before solar noon", "Solar
noon", "Sunset", "Night".

Through the day, the minute of sunrise or sunset is named outright, and
solar noon is five minutes long (its minute and two either side); the first
and last hour of daylight count minutes from sunrise or to sunset; the rest
of the day counts hours to and from solar noon (minutes in its last and
first hour). Civil twilight counts the minutes to sunrise or from sunset;
further out it's nautical or astronomical twilight, then night.

-}


{-| One day's sun, as ms since the epoch (the recorder's /live `sun`). An
event is Nothing on a day it doesn't happen.
-}
type alias Times a =
    { a
        | astronomicalDawn : Maybe Int
        , nauticalDawn : Maybe Int
        , civilDawn : Maybe Int
        , sunrise : Maybe Int
        , solarNoon : Int
        , sunset : Maybe Int
        , civilDusk : Maybe Int
        , nauticalDusk : Maybe Int
        , astronomicalDusk : Maybe Int
    }


{-| Counted in minutes from sunrise or to sunset this close, on the light
side; and in minutes to or from solar noon within this of it.
-}
daylightMinutes : Int
daylightMinutes =
    60


describe : Int -> Times a -> String
describe now sun =
    let
        -- Whole minutes from now to `t` (negative once it's past).
        minutesTo t =
            round (toFloat (t - now) / 60000)

        after t =
            Maybe.map (\ms -> now >= ms) t |> Maybe.withDefault False

        before t =
            Maybe.map (\ms -> now < ms) t |> Maybe.withDefault False

        -- Twilight bands, sunward first; civil twilight with the minutes to
        -- sunrise or since sunset (`fromSun`).
        darkness dawnSide fromSun =
            let
                ( civil, nautical, astronomical ) =
                    if dawnSide then
                        ( after sun.civilDawn, after sun.nauticalDawn, after sun.astronomicalDawn )

                    else
                        ( before sun.civilDusk, before sun.nauticalDusk, before sun.astronomicalDusk )
            in
            if civil then
                String.join ". " (List.filter (not << String.isEmpty) [ "Civil twilight", fromSun ])

            else if nautical then
                "Nautical twilight"

            else if astronomical then
                "Astronomical twilight"

            else
                "Night"
    in
    case ( sun.sunrise, sun.sunset ) of
        ( Just sunrise, Just sunset ) ->
            if now < sunrise then
                let
                    toSunrise =
                        minutesTo sunrise
                in
                if toSunrise == 0 then
                    "Sunrise"

                else
                    darkness True (count toSunrise "minute" ++ " before sunrise")

            else if now >= sunset then
                let
                    sinceSunset =
                        -(minutesTo sunset)
                in
                if sinceSunset == 0 then
                    "Sunset"

                else
                    darkness False (count sinceSunset "minute" ++ " after sunset")

            else
                let
                    sinceSunrise =
                        -(minutesTo sunrise)

                    toSunset =
                        minutesTo sunset

                    toNoon =
                        minutesTo sun.solarNoon
                in
                if sinceSunrise == 0 then
                    "Sunrise"

                else if toSunset == 0 then
                    "Sunset"

                else if sinceSunrise <= daylightMinutes then
                    count sinceSunrise "minute" ++ " after sunrise"

                else if toSunset <= daylightMinutes then
                    count toSunset "minute" ++ " before sunset"

                else if abs toNoon <= 2 then
                    "Solar noon"

                else if abs toNoon < daylightMinutes then
                    count (abs toNoon) "minute" ++ beforeOrAfter toNoon

                else
                    count (round (toFloat (abs toNoon) / 60)) "hour" ++ beforeOrAfter toNoon

        _ ->
            -- No sunrise or sunset today (not in New York): just the
            -- twilight bands, by which half of the day it is.
            darkness (now < sun.solarNoon) ""


beforeOrAfter : Int -> String
beforeOrAfter toNoon =
    if toNoon > 0 then
        " before solar noon"

    else
        " after solar noon"


count : Int -> String -> String
count n unit =
    if n == 1 then
        "1 " ++ unit

    else
        String.fromInt n ++ " " ++ unit ++ "s"

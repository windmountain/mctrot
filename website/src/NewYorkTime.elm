module NewYorkTime exposing (clock, format, isDaylight)

{-| Times as New York tells them, for every visitor wherever they are:
"November 21, 5:34 AM EST".

Elm's `Time` only knows UTC and the browser's own zone, so the US rule is
written out here: Eastern Daylight Time (UTC−4) from 2 AM on the second
Sunday of March to 2 AM on the first Sunday of November; Eastern Standard
Time (UTC−5) the rest of the year.

-}


hourMs : Int
hourMs =
    3600000


dayMs : Int
dayMs =
    24 * hourMs


{-| "November 21, 5:34 AM EST", for a time in ms since the epoch.
-}
format : Int -> String
format ms =
    let
        { month, day } =
            civilFromDays (floorDiv (local ms) dayMs)
    in
    monthName month ++ " " ++ String.fromInt day ++ ", " ++ clock ms ++ " " ++ zoneName ms


{-| Just the time of day in New York: "5:34 AM".
-}
clock : Int -> String
clock ms =
    let
        minuteOfDay =
            modBy dayMs (local ms) // 60000

        hour24 =
            minuteOfDay // 60

        hour12 =
            if modBy 12 hour24 == 0 then
                12

            else
                modBy 12 hour24
    in
    String.fromInt hour12
        ++ ":"
        ++ String.padLeft 2 '0' (String.fromInt (modBy 60 minuteOfDay))
        ++ (if hour24 < 12 then
                " AM"

            else
                " PM"
           )


zoneName : Int -> String
zoneName ms =
    if isDaylight ms then
        "EDT"

    else
        "EST"


{-| New York's wall-clock time, as ms since a local "epoch".
-}
local : Int -> Int
local ms =
    ms
        - (if isDaylight ms then
            4 * hourMs

           else
            5 * hourMs
          )


{-| Whether New York is on daylight time at this moment.
-}
isDaylight : Int -> Bool
isDaylight ms =
    let
        -- The year in New York: standard time is close enough to tell,
        -- since the changes are nowhere near New Year.
        { year } =
            civilFromDays (floorDiv (ms - 5 * hourMs) dayMs)

        -- 2 AM EST is 07:00 UTC; 2 AM EDT is 06:00 UTC.
        starts =
            nthSunday 2 year 3 * dayMs + 7 * hourMs

        ends =
            nthSunday 1 year 11 * dayMs + 6 * hourMs
    in
    ms >= starts && ms < ends


{-| The day number (days since 1970-01-01) of a month's nth Sunday.
-}
nthSunday : Int -> Int -> Int -> Int
nthSunday n year month =
    let
        first =
            daysFromCivil year month 1

        -- 1970-01-01 was a Thursday: weekday 4, counting Sunday as 0.
        weekday =
            modBy 7 (first + 4)
    in
    first + modBy 7 (7 - weekday) + 7 * (n - 1)


{-| Days since 1970-01-01 of a date in the proleptic Gregorian calendar
(Howard Hinnant's algorithm).
-}
daysFromCivil : Int -> Int -> Int -> Int
daysFromCivil year month day =
    let
        y =
            if month <= 2 then
                year - 1

            else
                year

        era =
            floorDiv y 400

        yoe =
            y - era * 400

        mp =
            modBy 12 (month + 9)

        doy =
            (153 * mp + 2) // 5 + day - 1

        doe =
            yoe * 365 + yoe // 4 - yoe // 100 + doy
    in
    era * 146097 + doe - 719468


civilFromDays : Int -> { year : Int, month : Int, day : Int }
civilFromDays days =
    let
        z =
            days + 719468

        era =
            floorDiv z 146097

        doe =
            z - era * 146097

        yoe =
            (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365

        doy =
            doe - (365 * yoe + yoe // 4 - yoe // 100)

        mp =
            (5 * doy + 2) // 153

        day =
            doy - (153 * mp + 2) // 5 + 1

        month =
            if mp < 10 then
                mp + 3

            else
                mp - 9
    in
    { year =
        yoe
            + era
            * 400
            + (if month <= 2 then
                1

               else
                0
              )
    , month = month
    , day = day
    }


floorDiv : Int -> Int -> Int
floorDiv a b =
    floor (toFloat a / toFloat b)


monthName : Int -> String
monthName month =
    case month of
        1 ->
            "January"

        2 ->
            "February"

        3 ->
            "March"

        4 ->
            "April"

        5 ->
            "May"

        6 ->
            "June"

        7 ->
            "July"

        8 ->
            "August"

        9 ->
            "September"

        10 ->
            "October"

        11 ->
            "November"

        _ ->
            "December"

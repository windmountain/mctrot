module Calendar exposing (Date, addDays, formatLong, formatShort, parseDate, sakamotoWeekday)

{-| Gregorian calendar dates as `( year, month, day )`, month and day
1-based, for the simulator's start date and the printed schedule (see
`Simulator.viewPrintSheet`). No time zones: a date is just a day on the
wall calendar in New York.
-}

import List.Extra


type alias Date =
    ( Int, Int, Int )


parseDate : String -> Maybe Date
parseDate isoDate =
    case String.split "-" isoDate |> List.map String.toInt of
        [ Just year, Just month, Just day ] ->
            Just ( year, month, day )

        _ ->
            Nothing


{-| Sakamoto's algorithm for the day of the week of a Gregorian date:
0 = Sunday .. 6 = Saturday.
-}
sakamotoWeekday : Int -> Int -> Int -> Int
sakamotoWeekday year month day =
    let
        offsets =
            [ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 ]

        y =
            if month < 3 then
                year - 1

            else
                year

        offset =
            List.Extra.getAt (month - 1) offsets |> Maybe.withDefault 0
    in
    modBy 7 (y + y // 4 - y // 100 + y // 400 + offset + day)


{-| Days since 1970-01-01, by Howard Hinnant's `days_from_civil`, for years
0 and later (`//` truncates toward zero, so negative years would be off).
-}
daysFromCivil : Date -> Int
daysFromCivil ( year, month, day ) =
    let
        y =
            if month <= 2 then
                year - 1

            else
                year

        era =
            y // 400

        yearOfEra =
            y - era * 400

        dayOfYear =
            (153 * modBy 12 (month + 9) + 2) // 5 + day - 1

        dayOfEra =
            yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
    in
    era * 146097 + dayOfEra - 719468


{-| The inverse of `daysFromCivil` (Hinnant's `civil_from_days`).
-}
civilFromDays : Int -> Date
civilFromDays days =
    let
        z =
            days + 719468

        era =
            z // 146097

        dayOfEra =
            z - era * 146097

        yearOfEra =
            (dayOfEra - dayOfEra // 1460 + dayOfEra // 36524 - dayOfEra // 146096) // 365

        dayOfYear =
            dayOfEra - (365 * yearOfEra + yearOfEra // 4 - yearOfEra // 100)

        shiftedMonth =
            (5 * dayOfYear + 2) // 153

        month =
            if shiftedMonth < 10 then
                shiftedMonth + 3

            else
                shiftedMonth - 9

        year =
            yearOfEra
                + era
                * 400
                + (if month <= 2 then
                    1

                   else
                    0
                  )
    in
    ( year, month, dayOfYear - (153 * shiftedMonth + 2) // 5 + 1 )


{-| `n` days later (or earlier, if negative), across month and year ends.
-}
addDays : Int -> Date -> Date
addDays n date =
    civilFromDays (daysFromCivil date + n)


weekdayName : Date -> String
weekdayName ( year, month, day ) =
    List.Extra.getAt (sakamotoWeekday year month day)
        [ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" ]
        |> Maybe.withDefault ""


monthName : Int -> String
monthName month =
    List.Extra.getAt (month - 1)
        [ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" ]
        |> Maybe.withDefault ""


{-| "Saturday, November 21, 2026"
-}
formatLong : Date -> String
formatLong (( year, month, day ) as date) =
    weekdayName date ++ ", " ++ monthName month ++ " " ++ String.fromInt day ++ ", " ++ String.fromInt year


{-| "Sun Nov 22"
-}
formatShort : Date -> String
formatShort (( _, month, day ) as date) =
    String.left 3 (weekdayName date) ++ " " ++ String.left 3 (monthName month) ++ " " ++ String.fromInt day

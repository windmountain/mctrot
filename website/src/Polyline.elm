module Polyline exposing (decode)

{-| Google's encoded polyline format (precision 5), as written by
scripts/export_simulator_data.py for each walking leg in geo/route-legs.json.
-}

import Bitwise


{-| The `( lat, lon )` points, in degrees. Stops at the first malformed
value.
-}
decode : String -> List ( Float, Float )
decode encoded =
    decodeHelp (String.toList encoded |> List.map (\c -> Char.toCode c - 63)) 0 0 []


decodeHelp : List Int -> Int -> Int -> List ( Float, Float ) -> List ( Float, Float )
decodeHelp codes lat lon acc =
    case readValue codes 0 0 of
        Nothing ->
            List.reverse acc

        Just ( dLat, rest ) ->
            case readValue rest 0 0 of
                Nothing ->
                    List.reverse acc

                Just ( dLon, rest2 ) ->
                    decodeHelp rest2 (lat + dLat) (lon + dLon) (( toFloat (lat + dLat) / 1.0e5, toFloat (lon + dLon) / 1.0e5 ) :: acc)


{-| One signed value: 5-bit chunks, least significant first, with 0x20 set
on every chunk but the last; the sign is in the lowest bit.
-}
readValue : List Int -> Int -> Int -> Maybe ( Int, List Int )
readValue codes shift result =
    case codes of
        [] ->
            Nothing

        c :: rest ->
            let
                result2 =
                    Bitwise.or result (Bitwise.shiftLeftBy shift (Bitwise.and c 0x1F))
            in
            if c >= 0x20 then
                readValue rest (shift + 5) result2

            else if Bitwise.and result2 1 == 1 then
                Just ( Bitwise.complement (Bitwise.shiftRightZfBy 1 result2), rest )

            else
                Just ( Bitwise.shiftRightZfBy 1 result2, rest )

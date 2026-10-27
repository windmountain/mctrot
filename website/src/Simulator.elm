module Simulator exposing (main)

{-| The interactive route simulator on simulator.html, mounted with
`Elm.Simulator.init({ node, flags: today })` (see `init`).

  - The energy function isn't a simple sum of edge weights — it has to walk
    the tour in order, carrying an accumulated clock forward, because
    whether you wait at a restaurant depends on when you arrive (see
    `simulate`).
  - The search's starting seed comes from a user-editable text field (see
    `SetSeedInput`, `parseSeed`), converted to a `Random.Seed` via
    `Random.initialSeed` — deterministic, so the whole search starts
    synchronously in `init`/`startSearch`, with no `Cmd`-driven randomness.

47 real McDonald's locations in Manhattan, named by their real nicknames and
real per-weekday hours (`data/mcd_locations.csv`), connected by real road
distances in meters (`data/route_summary.csv`). This is an open path, not a round
trip: it can start at any of the 47 locations, but must end at "OCCUPY" (160
Broadway). Most locations are open 24 hours; a handful have real weekly
schedules — including days that are fully open, days that close at midnight,
and one or two nights that run past midnight into the next calendar day —
and arriving while closed means waiting for the next opening, which the UI's
start date picker determines (see `weekdayName`). Travel time between stops
is the raw distance converted at a pace the UI also asks for, in
minutes/mile (see `travelTime`).
-}

import Array exposing (Array)
import Browser
import Browser.Events
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy
import List.Extra
import MctrotMapData
import Random
import SimulatedAnnealing exposing (Config, State)
import SimulatedAnnealing.Schedule as Schedule
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr



-- PROBLEM DEFINITION


{-| `openWindows`/`closedWindows` are minutes-since-Monday-00:00 in a
repeating 7-day (10080-minute) week, precomputed from `mcd_locations.csv`'s
`hours` column (`Mon 06:00 - 00:00; Tue ...`) — including merging adjacent
open days together and splitting any window that crosses the Sunday/Monday
seam. Always-open locations get a single `( 0, 10080 )` window and no closed
windows at all. The two lists are complements of each other within the
week; both are kept so neither `waitForCity` nor the view has to compute a
complement at runtime.
-}
type alias City =
    { name : String
    , openWindows : List ( Int, Int )
    , closedWindows : List ( Int, Int )
    }


{-| Index 46 ("OCCUPY") is the fixed finish line — see `endIndex`.
-}
cities : Array City
cities =
    Array.fromList
        [ City "DRIVETHRU" [ ( 0, 10080 ) ] []
        , City "ACP" [ ( 0, 10080 ) ] []
        , City "RIVERVIEW" [ ( 0, 10080 ) ] []
        , City "BRACES" [ ( 0, 10080 ) ] []
        , City "COLUMBIA" [ ( 0, 10080 ) ] []
        , City "RAMP" [ ( 0, 10080 ) ] []
        , City "BIGMAC" [ ( 0, 10080 ) ] []
        , City "SHIP" [ ( 0, 10080 ) ] []
        , City "TITANIC" [ ( 0, 10080 ) ] []
        , City "103" [ ( 0, 10080 ) ] []
        , City "CHAMFER" [ ( 0, 10080 ) ] []
        , City "OG" [ ( 0, 10080 ) ] []
        , City "METROPOLITAN" [ ( 0, 10080 ) ] []
        , City "CLOCK" [ ( 0, 10080 ) ] []
        , City "STRADDLER" [ ( 0, 10080 ) ] []
        , City "72ND" [ ( 0, 10080 ) ] []
        , City "SLOPER" [ ( 0, 10080 ) ] []
        , City "CORNELL" [ ( 0, 10080 ) ] []
        , City "STIJL" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 8640, 9000 ) ]
        , City "PUNCH" [ ( 0, 10080 ) ] []
        , City "CHURCH" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 4320 ), ( 4680, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 4320, 4680 ), ( 8640, 9000 ) ]
        , City "SHORTY" [ ( 0, 10080 ) ] []
        , City "CONNOLY'S" [ ( 360, 1380 ), ( 1800, 2820 ), ( 3240, 4260 ), ( 4680, 5700 ), ( 6120, 7140 ), ( 7560, 8580 ), ( 9000, 10020 ) ] [ ( 0, 360 ), ( 1380, 1800 ), ( 2820, 3240 ), ( 4260, 4680 ), ( 5700, 6120 ), ( 7140, 7560 ), ( 8580, 9000 ), ( 10020, 10080 ) ]
        , City "WHORL" [ ( 0, 10080 ) ] []
        , City "SHOWCASE" [ ( 0, 10080 ) ] []
        , City "GIRAFFE" [ ( 0, 10080 ) ] []
        , City "PIANO FACTORY" [ ( 0, 10080 ) ] []
        , City "7TH" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 4320 ), ( 4680, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 4320, 4680 ), ( 8640, 9000 ) ]
        , City "B&H" [ ( 0, 10080 ) ] []
        , City "MACY" [ ( 0, 10080 ) ] []
        , City "PENN" [ ( 0, 10080 ) ] []
        , City "SHORTY II" [ ( 240, 1440 ), ( 1830, 2880 ), ( 3270, 8640 ), ( 8880, 10080 ) ] [ ( 0, 240 ), ( 1440, 1830 ), ( 2880, 3270 ), ( 8640, 8880 ) ]
        , City "MCCAFE PUNK" [ ( 0, 10080 ) ] []
        , City "PARK" [ ( 0, 10080 ) ] []
        , City "SHORTY III" [ ( 420, 1380 ), ( 1860, 2820 ), ( 3300, 4260 ), ( 4740, 5700 ), ( 6180, 7200 ), ( 7620, 8640 ), ( 9060, 10020 ) ] [ ( 0, 420 ), ( 1380, 1860 ), ( 2820, 3300 ), ( 4260, 4740 ), ( 5700, 6180 ), ( 7200, 7620 ), ( 8640, 9060 ), ( 10020, 10080 ) ]
        , City "MICHAELS" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 4320 ), ( 4680, 5760 ), ( 6120, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 4320, 4680 ), ( 5760, 6120 ), ( 8640, 9000 ) ]
        , City "TALLBOY" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 8640, 9000 ) ]
        , City "UNION" [ ( 360, 1440 ), ( 1800, 2880 ), ( 3240, 4320 ), ( 4680, 5760 ), ( 6120, 7200 ), ( 7560, 8640 ), ( 9000, 10080 ) ] [ ( 0, 360 ), ( 1440, 1800 ), ( 2880, 3240 ), ( 4320, 4680 ), ( 5760, 6120 ), ( 7200, 7560 ), ( 8640, 9000 ) ]
        , City "OVERLAND" [ ( 420, 1440 ), ( 1860, 2880 ), ( 3300, 4320 ), ( 4740, 8640 ), ( 9060, 10080 ) ] [ ( 0, 420 ), ( 1440, 1860 ), ( 2880, 3300 ), ( 4320, 4740 ), ( 8640, 9060 ) ]
        , City "IMMACULATE" [ ( 0, 10080 ) ] []
        , City "NYU" [ ( 0, 10080 ) ] []
        , City "VARICK" [ ( 0, 10080 ) ] []
        , City "麦当劳" [ ( 390, 1440 ), ( 1830, 2880 ), ( 3270, 4320 ), ( 4710, 5760 ), ( 6150, 7200 ), ( 7590, 8640 ), ( 9030, 10080 ) ] [ ( 0, 390 ), ( 1440, 1830 ), ( 2880, 3270 ), ( 4320, 4710 ), ( 5760, 6150 ), ( 7200, 7590 ), ( 8640, 9030 ) ]
        , City "GREENHOUSE" [ ( 420, 1440 ), ( 1860, 2880 ), ( 3300, 8640 ), ( 9060, 10080 ) ] [ ( 0, 420 ), ( 1440, 1860 ), ( 2880, 3300 ), ( 8640, 9060 ) ]
        , City "DELANCEY" [ ( 0, 10080 ) ] []
        , City "GREENWICH" [ ( 0, 10080 ) ] []
        , City "OCCUPY" [ ( 0, 10080 ) ] []
        ]


{-| Road distance in meters between every pair of the 47 stops, taken
directly from `route_summary.csv` (sorted by mcd_id, symmetric). This is
*not* a travel time — `travelTime` converts it to minutes using an assumed
average speed, so the schedule math below never touches raw meters.
-}
distanceMeters : Array (Array Int)
distanceMeters =
    Array.fromList
        [ Array.fromList [ 0, 1127, 1527, 1509, 2005, 2475, 2706, 3143, 3706, 3846, 4062, 4438, 4505, 5308, 5767, 6262, 6061, 6848, 7498, 6961, 7374, 8144, 7969, 8015, 7942, 8080, 8219, 8269, 8636, 8660, 8831, 9511, 9264, 9641, 9854, 9748, 10530, 10224, 10279, 11221, 11267, 11508, 12607, 11759, 12755, 13088, 13777 ]
        , Array.fromList [ 1127, 0, 2529, 420, 1180, 3507, 1795, 4175, 2579, 2771, 5093, 3311, 3462, 4231, 6895, 5135, 7188, 5897, 6412, 5834, 6247, 7060, 6841, 6887, 6815, 6953, 7092, 7141, 7509, 7533, 7703, 8415, 8137, 8513, 8727, 8620, 9550, 9096, 9152, 10209, 10140, 10380, 11480, 10632, 11627, 11961, 12650 ]
        , Array.fromList [ 1527, 2529, 0, 2109, 1358, 1127, 4063, 2037, 3344, 4964, 2955, 4070, 5655, 6423, 4854, 6072, 5418, 8090, 8605, 7420, 7888, 9251, 8996, 8529, 8456, 8539, 9157, 8783, 9095, 9175, 9345, 10331, 9779, 10266, 10374, 10262, 11286, 10743, 10794, 11855, 11787, 12022, 13127, 12279, 13274, 13471, 14291 ]
        , Array.fromList [ 1509, 420, 2109, 0, 760, 3133, 2015, 3801, 2252, 2916, 4719, 2984, 3608, 4376, 6618, 4808, 7090, 6043, 6557, 5717, 6130, 7205, 6987, 6771, 6698, 6836, 7237, 7024, 7392, 7416, 7586, 8561, 8020, 8508, 8615, 8503, 9527, 8985, 9035, 10097, 10028, 10264, 11368, 10520, 11516, 11844, 12533 ]
        , Array.fromList [ 2005, 1180, 1358, 760, 0, 2484, 2714, 3395, 1986, 3615, 4313, 2712, 4306, 5074, 6211, 4714, 6775, 6741, 7256, 6062, 6531, 7893, 7638, 7172, 7099, 7181, 7800, 7425, 7737, 7817, 7987, 8973, 8421, 8909, 9016, 8904, 9928, 9386, 9436, 10498, 10429, 10665, 11769, 10921, 11917, 12114, 12934 ]
        , Array.fromList [ 2475, 3507, 1127, 3133, 2484, 0, 4782, 910, 4471, 5922, 1829, 5196, 6581, 7384, 3727, 7199, 4291, 8924, 9575, 8547, 9015, 10220, 10120, 9656, 9583, 9666, 10284, 9910, 10222, 10302, 10472, 11458, 10905, 11393, 11500, 11389, 12412, 11870, 11921, 12982, 12913, 13149, 14254, 13405, 14401, 14598, 15418 ]
        , Array.fromList [ 2706, 1795, 4063, 2015, 2714, 4782, 0, 5450, 3105, 1140, 6298, 3836, 1831, 2602, 7948, 5517, 8241, 4266, 4793, 6132, 6445, 5438, 6132, 6585, 6924, 7251, 6677, 7251, 7807, 7643, 7813, 6805, 8103, 7487, 8038, 8586, 7919, 8479, 9118, 8610, 9169, 10334, 10481, 9250, 10289, 11586, 11704 ]
        , Array.fromList [ 3143, 4175, 2037, 3801, 3395, 910, 5450, 0, 5375, 6590, 954, 6107, 7249, 8052, 2852, 8109, 3416, 9592, 10243, 9457, 9925, 10888, 10788, 10566, 10493, 10576, 11038, 10820, 11132, 11212, 11382, 12255, 11816, 12303, 12411, 12299, 13275, 12780, 12831, 13892, 13824, 14059, 15164, 14316, 15311, 15508, 16328 ]
        , Array.fromList [ 3706, 2579, 3344, 2252, 1986, 4471, 3105, 5375, 0, 2821, 6293, 750, 2931, 3553, 8191, 2752, 8755, 5263, 5393, 4100, 4568, 5931, 5676, 5209, 5136, 5219, 5838, 5463, 5775, 5855, 6025, 7011, 6459, 6946, 7054, 6942, 7966, 7423, 7474, 8535, 8467, 8702, 9807, 8959, 9954, 10151, 10971 ]
        , Array.fromList [ 3846, 2771, 4964, 2916, 3615, 5922, 1140, 6590, 2821, 0, 7438, 2713, 691, 1462, 9088, 4388, 9381, 3126, 3652, 4997, 5310, 4298, 4993, 5450, 5790, 6116, 5538, 6116, 6672, 6508, 6678, 5665, 6963, 6347, 6898, 7446, 6778, 7339, 7978, 7469, 8028, 9193, 9341, 8110, 9149, 10446, 10564 ]
        , Array.fromList [ 4062, 5093, 2955, 4719, 4313, 1829, 6298, 954, 6293, 7438, 0, 7025, 8097, 8900, 1898, 9027, 2462, 10440, 11090, 10375, 10844, 11736, 11706, 11485, 11412, 11494, 11956, 11738, 12050, 12130, 12300, 13103, 12734, 13222, 13329, 13217, 14122, 13699, 13749, 14811, 14742, 14978, 16082, 15234, 16230, 16427, 17247 ]
        , Array.fromList [ 4438, 3311, 4070, 2984, 2712, 5196, 3836, 6107, 750, 2713, 7025, 0, 2544, 2867, 8923, 2003, 9487, 4552, 4644, 3351, 3819, 5181, 4926, 4460, 4387, 4469, 5088, 4713, 5025, 5105, 5275, 6261, 5709, 6197, 6304, 6192, 7216, 6674, 6724, 7786, 7717, 7953, 9057, 8209, 9205, 9402, 10222 ]
        , Array.fromList [ 4505, 3462, 5655, 3608, 4306, 6581, 1831, 7249, 2931, 691, 8097, 2544, 0, 1111, 9747, 4061, 10040, 2435, 3300, 4650, 4963, 3944, 4644, 5103, 5442, 5769, 5187, 5769, 6325, 6161, 6331, 5280, 6602, 5974, 6534, 7084, 6087, 6966, 7614, 6778, 7600, 8815, 8912, 7418, 8458, 10017, 10135 ]
        , Array.fromList [ 5308, 4231, 6423, 4376, 5074, 7384, 2602, 8052, 3553, 1462, 8900, 2867, 1111, 0, 10550, 3011, 10843, 1755, 2191, 3542, 3855, 2836, 3535, 3994, 4334, 4661, 4078, 4661, 5217, 5053, 5223, 4203, 5503, 4885, 5438, 5986, 5407, 5877, 6518, 6098, 6566, 7732, 7879, 6738, 7770, 8984, 9102 ]
        , Array.fromList [ 5767, 6895, 4854, 6618, 6211, 3727, 7948, 2852, 8191, 9088, 1898, 8923, 9747, 10550, 0, 10926, 564, 12089, 12740, 12274, 12742, 13386, 13420, 13383, 13310, 13392, 13855, 13636, 13948, 14028, 14198, 14753, 14632, 15039, 15227, 15115, 15772, 15597, 15647, 16463, 16640, 16876, 17980, 17103, 18128, 18325, 19145 ]
        , Array.fromList [ 6262, 5135, 6072, 4808, 4714, 7199, 5517, 8109, 2752, 4388, 9027, 2003, 4061, 3011, 10926, 0, 11490, 2923, 2641, 1348, 1816, 3179, 2924, 2457, 2384, 2467, 3085, 2711, 3023, 3103, 3273, 4259, 3707, 4194, 4301, 4190, 5214, 4671, 4722, 5783, 5714, 5950, 7055, 6206, 7202, 7399, 8219 ]
        , Array.fromList [ 6061, 7188, 5418, 7090, 6775, 4291, 8241, 3416, 8755, 9381, 2462, 9487, 10040, 10843, 564, 11490, 0, 12383, 13034, 12783, 13195, 13679, 13714, 13836, 13763, 13902, 14182, 14090, 14458, 14482, 14652, 15046, 15086, 15332, 15633, 15569, 16066, 16050, 16101, 16757, 17094, 17329, 18434, 17397, 18436, 18889, 19598 ]
        , Array.fromList [ 6848, 5897, 8090, 6043, 6741, 8924, 4266, 9592, 5263, 3126, 10440, 4552, 2435, 1755, 12089, 2923, 12383, 0, 1291, 2757, 3070, 1933, 2634, 3099, 3549, 3876, 3177, 3876, 4432, 4268, 4438, 3269, 4591, 3963, 4523, 5073, 3683, 4955, 5603, 4374, 5569, 6784, 6881, 5014, 6053, 7986, 8104 ]
        , Array.fromList [ 7498, 6412, 8605, 6557, 7256, 9575, 4793, 10243, 5393, 3652, 11090, 4644, 3300, 2191, 12740, 2641, 13034, 1291, 0, 1647, 1847, 655, 1347, 1812, 2292, 2749, 1890, 2638, 3303, 3030, 3198, 2022, 3315, 2697, 3250, 3798, 3234, 3689, 4330, 3925, 4385, 5544, 5698, 4565, 5588, 6802, 6921 ]
        , Array.fromList [ 6961, 5834, 7420, 5717, 6062, 8547, 6132, 9457, 4100, 4997, 10375, 3351, 4650, 3542, 12274, 1348, 12783, 2757, 1647, 0, 536, 1899, 1644, 1177, 1105, 1119, 1806, 1431, 1675, 1823, 1993, 2979, 2427, 2915, 3022, 2910, 3934, 3392, 3442, 4504, 4435, 4662, 5775, 4927, 5922, 6127, 6940 ]
        , Array.fromList [ 7374, 6247, 7888, 6130, 6531, 9015, 6445, 9925, 4568, 5310, 10844, 3819, 4963, 3855, 12742, 1816, 13195, 3070, 1847, 536, 0, 1363, 1108, 641, 568, 916, 1269, 895, 1472, 1287, 1457, 2443, 1890, 2378, 2485, 2374, 3397, 2855, 2906, 3967, 3898, 4134, 5239, 4390, 5386, 5809, 6403 ]
        , Array.fromList [ 8144, 7060, 9251, 7205, 7893, 10220, 5438, 10888, 5931, 4298, 11736, 5181, 3944, 2836, 13386, 3179, 13679, 1933, 655, 1899, 1363, 0, 704, 1171, 1650, 2106, 1247, 1995, 2661, 2387, 2555, 1367, 2672, 2054, 2607, 3155, 2583, 3045, 3687, 3274, 3731, 4900, 5043, 3914, 4934, 6148, 6266 ]
        , Array.fromList [ 7969, 6841, 8996, 6987, 7638, 10120, 6132, 10788, 5676, 4993, 11706, 4926, 4644, 3535, 13420, 2924, 13714, 2634, 1347, 1644, 1108, 704, 0, 467, 960, 1414, 558, 1304, 1970, 1696, 1866, 1577, 1984, 1672, 1919, 2467, 2792, 2510, 2999, 3483, 3474, 4263, 4814, 3933, 4929, 5702, 6010 ]
        , Array.fromList [ 8015, 6887, 8529, 6771, 7172, 9656, 6585, 10566, 5209, 5450, 11485, 4460, 5103, 3994, 13383, 2457, 13836, 3099, 1812, 1177, 641, 1171, 467, 0, 495, 948, 715, 838, 1504, 1230, 1400, 2044, 1521, 2009, 2116, 2004, 3028, 2485, 2536, 3598, 3529, 3871, 4869, 4021, 5016, 5516, 6033 ]
        , Array.fromList [ 7942, 6815, 8456, 6698, 7099, 9583, 6924, 10493, 5136, 5790, 11412, 4387, 5442, 4334, 13310, 2384, 13763, 3549, 2292, 1105, 568, 1650, 960, 495, 0, 457, 701, 347, 1013, 739, 909, 1874, 1322, 1810, 1917, 1806, 2829, 2287, 2337, 3399, 3330, 3586, 4670, 3822, 4818, 5262, 5835 ]
        , Array.fromList [ 8080, 6953, 8539, 6836, 7181, 9666, 7251, 10576, 5219, 6116, 11494, 4469, 5769, 4661, 13392, 2467, 13902, 3876, 2749, 1119, 916, 2106, 1414, 948, 457, 0, 860, 437, 556, 829, 999, 2033, 1481, 1969, 2076, 1964, 2988, 2445, 2496, 3558, 3489, 3543, 4825, 3981, 4976, 5008, 5852 ]
        , Array.fromList [ 8219, 7092, 9157, 7237, 7800, 10284, 6677, 11038, 5838, 5538, 11956, 5088, 5187, 4078, 13855, 3085, 14182, 3177, 1890, 1806, 1269, 1247, 558, 715, 701, 860, 0, 749, 1414, 1140, 1309, 1339, 1426, 1426, 1635, 1909, 2547, 2005, 2441, 3117, 3048, 3706, 4388, 3540, 4536, 5197, 5584 ]
        , Array.fromList [ 8269, 7141, 8783, 7024, 7425, 9910, 7251, 10820, 5463, 6116, 11738, 4713, 5769, 4661, 13636, 2711, 14090, 3876, 2638, 1431, 895, 1995, 1304, 838, 347, 437, 749, 0, 666, 392, 562, 1635, 1083, 1571, 1678, 1566, 2590, 2048, 2098, 3160, 3091, 3239, 4431, 3583, 4579, 4915, 5584 ]
        , Array.fromList [ 8636, 7509, 9095, 7392, 7737, 10222, 7807, 11132, 5775, 6672, 12050, 5025, 6325, 5217, 13948, 3023, 14458, 4432, 3303, 1675, 1472, 2661, 1970, 1504, 1013, 556, 1414, 666, 0, 274, 443, 1625, 1072, 1560, 1667, 1556, 2579, 2037, 2088, 3149, 3080, 2987, 4270, 3572, 4568, 4452, 5296 ]
        , Array.fromList [ 8660, 7533, 9175, 7416, 7817, 10302, 7643, 11212, 5855, 6508, 12130, 5105, 6161, 5053, 14028, 3103, 14482, 4268, 3030, 1823, 1287, 2387, 1696, 1230, 739, 829, 1140, 392, 274, 0, 170, 1350, 798, 1286, 1393, 1281, 2305, 1763, 1813, 2875, 2806, 2847, 4130, 3298, 4294, 4523, 5192 ]
        , Array.fromList [ 8831, 7703, 9345, 7586, 7987, 10472, 7813, 11382, 6025, 6678, 12300, 5275, 6331, 5223, 14198, 3273, 14652, 4438, 3198, 1993, 1457, 2555, 1866, 1400, 909, 999, 1309, 562, 443, 170, 0, 1338, 665, 1172, 1279, 1148, 2191, 1648, 1680, 2761, 2692, 2677, 3960, 3184, 4179, 4352, 5022 ]
        , Array.fromList [ 9511, 8415, 10331, 8561, 8973, 11458, 6805, 12255, 7011, 5665, 13103, 6261, 5280, 4203, 14753, 4259, 15046, 3269, 2022, 2979, 2443, 1367, 1577, 2044, 1874, 2033, 1339, 1635, 1625, 1350, 1338, 0, 1323, 696, 1255, 1805, 1231, 1687, 2335, 1922, 2363, 3541, 3676, 2561, 3567, 4781, 4899 ]
        , Array.fromList [ 9264, 8137, 9779, 8020, 8421, 10905, 8103, 11816, 6459, 6963, 12734, 5709, 6602, 5503, 14632, 3707, 15086, 4591, 3315, 2427, 1890, 2672, 1984, 1521, 1322, 1481, 1426, 1083, 1072, 798, 665, 1323, 0, 628, 735, 483, 1647, 1105, 1015, 2217, 2148, 2350, 3451, 2640, 3636, 3995, 4513 ]
        , Array.fromList [ 9641, 8513, 10266, 8508, 8909, 11393, 7487, 12303, 6946, 6347, 13222, 6197, 5974, 4885, 15039, 4194, 15332, 3963, 2697, 2915, 2378, 2054, 1672, 2009, 1810, 1969, 1426, 1571, 1560, 1286, 1172, 696, 628, 0, 560, 1109, 1143, 992, 1640, 1832, 1824, 2846, 3164, 2262, 3258, 4156, 4360 ]
        , Array.fromList [ 9854, 8727, 10374, 8615, 9016, 11500, 8038, 12411, 7054, 6898, 13329, 6304, 6534, 5438, 15227, 4301, 15633, 4523, 3250, 3022, 2485, 2607, 1919, 2116, 1917, 2076, 1635, 1678, 1667, 1393, 1279, 1255, 735, 560, 0, 550, 912, 591, 1081, 1595, 1566, 2345, 2906, 2025, 3021, 3784, 4102 ]
        , Array.fromList [ 9748, 8620, 10262, 8503, 8904, 11389, 8586, 12299, 6942, 7446, 13217, 6192, 7084, 5986, 15115, 4190, 15569, 5073, 3798, 2910, 2374, 3155, 2467, 2004, 1806, 1964, 1909, 1566, 1556, 1281, 1148, 1805, 483, 1109, 550, 0, 1462, 769, 532, 1881, 1812, 1867, 2968, 2304, 3300, 3512, 4029 ]
        , Array.fromList [ 10530, 9550, 11286, 9527, 9928, 12412, 7919, 13275, 7966, 6778, 14122, 7216, 6087, 5407, 15772, 5214, 16066, 3683, 3234, 3934, 3397, 2583, 2792, 3028, 2829, 2988, 2547, 2590, 2579, 2305, 2191, 1231, 1647, 1143, 912, 1462, 0, 1342, 1990, 691, 1941, 3156, 3253, 1331, 2371, 4358, 4422 ]
        , Array.fromList [ 10224, 9096, 10743, 8985, 9386, 11870, 8479, 12780, 7423, 7339, 13699, 6674, 6966, 5877, 15597, 4671, 16050, 4955, 3689, 3392, 2855, 3045, 2510, 2485, 2287, 2445, 2005, 2048, 2037, 1763, 1648, 1687, 1105, 992, 591, 769, 1342, 0, 648, 1112, 1043, 1883, 2383, 1535, 2531, 3193, 3579 ]
        , Array.fromList [ 10279, 9152, 10794, 9035, 9436, 11921, 9118, 12831, 7474, 7978, 13749, 6724, 7614, 6518, 15647, 4722, 16101, 5603, 4330, 3442, 2906, 3687, 2999, 2536, 2337, 2496, 2441, 2098, 2088, 1813, 1680, 2335, 1015, 1640, 1081, 532, 1990, 648, 0, 1646, 1381, 1335, 2436, 1905, 2900, 2980, 3498 ]
        , Array.fromList [ 11221, 10209, 11855, 10097, 10498, 12982, 8610, 13892, 8535, 7469, 14811, 7786, 6778, 6098, 16463, 5783, 16757, 4374, 3925, 4504, 3967, 3274, 3483, 3598, 3399, 3558, 3117, 3160, 3149, 2875, 2761, 1922, 2217, 1832, 1595, 1881, 691, 1112, 1646, 0, 1419, 2634, 2732, 808, 1680, 3836, 3900 ]
        , Array.fromList [ 11267, 10140, 11787, 10028, 10429, 12913, 9169, 13824, 8467, 8028, 14742, 7717, 7600, 6566, 16640, 5714, 17094, 5569, 4385, 4435, 3898, 3731, 3474, 3529, 3330, 3489, 3048, 3091, 3080, 2806, 2692, 2363, 2148, 1824, 1566, 1812, 1941, 1043, 1381, 1419, 0, 1216, 1340, 939, 1635, 2417, 2536 ]
        , Array.fromList [ 11508, 10380, 12022, 10264, 10665, 13149, 10334, 14059, 8702, 9193, 14978, 7953, 8815, 7732, 16876, 5950, 17329, 6784, 5544, 4662, 4134, 4900, 4263, 3871, 3586, 3543, 3706, 3239, 2987, 2847, 2677, 3541, 2350, 2846, 2345, 1867, 3156, 1883, 1335, 2634, 1216, 0, 1284, 1995, 2110, 1675, 2346 ]
        , Array.fromList [ 12607, 11480, 13127, 11368, 11769, 14254, 10481, 15164, 9807, 9341, 16082, 9057, 8912, 7879, 17980, 7055, 18434, 6881, 5698, 5775, 5239, 5043, 4814, 4869, 4670, 4825, 4388, 4431, 4270, 4130, 3960, 3676, 3451, 3164, 2906, 2968, 3253, 2383, 2436, 2732, 1340, 1284, 0, 1998, 1385, 1202, 1320 ]
        , Array.fromList [ 11759, 10632, 12279, 10520, 10921, 13405, 9250, 14316, 8959, 8110, 15234, 8209, 7418, 6738, 17103, 6206, 17397, 5014, 4565, 4927, 4390, 3914, 3933, 4021, 3822, 3981, 3540, 3583, 3572, 3298, 3184, 2561, 2640, 2262, 2025, 2304, 1331, 1535, 1905, 808, 939, 1995, 1998, 0, 1054, 3119, 3091 ]
        , Array.fromList [ 12755, 11627, 13274, 11516, 11917, 14401, 10289, 15311, 9954, 9149, 16230, 9205, 8458, 7770, 18128, 7202, 18436, 6053, 5588, 5922, 5386, 4934, 4929, 5016, 4818, 4976, 4536, 4579, 4568, 4294, 4179, 3567, 3636, 3258, 3021, 3300, 2371, 2531, 2900, 1680, 1635, 2110, 1385, 1054, 0, 2484, 2366 ]
        , Array.fromList [ 13088, 11961, 13471, 11844, 12114, 14598, 11586, 15508, 10151, 10446, 16427, 9402, 10017, 8984, 18325, 7399, 18889, 7986, 6802, 6127, 5809, 6148, 5702, 5516, 5262, 5008, 5197, 4915, 4452, 4523, 4352, 4781, 3995, 4156, 3784, 3512, 4358, 3193, 2980, 3836, 2417, 1675, 1202, 3119, 2484, 0, 866 ]
        , Array.fromList [ 13777, 12650, 14291, 12533, 12934, 15418, 11704, 16328, 10971, 10564, 17247, 10222, 10135, 9102, 19145, 8219, 19598, 8104, 6921, 6940, 6403, 6266, 6010, 6033, 5835, 5852, 5584, 5584, 5296, 5192, 5022, 4899, 4513, 4360, 4102, 4029, 4422, 3579, 3498, 3900, 2536, 2346, 1320, 3091, 2366, 866, 0 ]
        ]


metersPerMile : Float
metersPerMile =
    1609.344


{-| Parses the value of the pace `<input type="number">` (minutes per
mile). Falls back to a brisk-walk pace if the field is ever empty,
non-numeric, or non-positive.
-}
parseMinutesPerMile : String -> Float
parseMinutesPerMile raw =
    case String.toFloat raw of
        Just minutesPerMile ->
            if minutesPerMile > 0 then
                minutesPerMile

            else
                defaultMinutesPerMile

        Nothing ->
            defaultMinutesPerMile


defaultMinutesPerMile : Float
defaultMinutesPerMile =
    24


{-| Parses the value of the stop time `<input type="number">` (whole
minutes spent at each location). Falls back to the default if the field is
ever empty, non-numeric, or negative.
-}
parseStopMinutes : String -> Int
parseStopMinutes raw =
    case String.toInt raw of
        Just minutes ->
            if minutes >= 0 then
                minutes

            else
                defaultStopMinutes

        Nothing ->
            defaultStopMinutes


defaultStopMinutes : Int
defaultStopMinutes =
    5


metersPerMinuteFromPace : Float -> Float
metersPerMinuteFromPace minutesPerMile =
    metersPerMile / minutesPerMile


{-| `metersPerMinute` is derived from the pace picker (minutes/mile) rather
than passed as a speed directly, since "minutes per mile" is what the UI
asks for — this is the one place that conversion happens, everything else
just uses the resulting rate.
-}
travelTime : Float -> Int -> Int -> Int
travelTime metersPerMinute from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0
        |> toFloat
        |> (\meters -> meters / metersPerMinute)
        |> round


{-| The route must finish here: "OCCUPY", 160 Broadway. Looked up by name
rather than hardcoded so it stays correct if `cities` is ever reordered.
-}
endIndex : Int
endIndex =
    cities
        |> Array.toIndexedList
        |> List.filter (\( _, city ) -> city.name == "OCCUPY")
        |> List.head
        |> Maybe.map Tuple.first
        |> Maybe.withDefault 0


{-| Parses the value of an `<input type="time">` ("HH:MM") into minutes
since midnight. Falls back to 6:00 AM if the field is ever empty or
malformed.
-}
parseStartMinutes : String -> Int
parseStartMinutes timeOfDay =
    case String.split ":" timeOfDay |> List.map String.toInt of
        [ Just hh, Just mm ] ->
            hh * 60 + mm

        _ ->
            6 * 60


{-| Parses the value of the seed text input into the `Int` `Random.initialSeed`
needs. Falls back to 0 if the field is ever empty or non-numeric.
-}
parseSeed : String -> Int
parseSeed raw =
    String.toInt raw |> Maybe.withDefault 0


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


parseDate : String -> Maybe ( Int, Int, Int )
parseDate isoDate =
    case String.split "-" isoDate |> List.map String.toInt of
        [ Just year, Just month, Just day ] ->
            Just ( year, month, day )

        _ ->
            Nothing


{-| Turns the value of an `<input type="date">` ("YYYY-MM-DD") into a
weekday name, for display next to the picker.
-}
weekdayName : String -> Maybe String
weekdayName isoDate =
    parseDate isoDate
        |> Maybe.andThen
            (\( year, month, day ) ->
                [ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" ]
                    |> List.Extra.getAt (sakamotoWeekday year month day)
            )


{-| Same date, but as a Monday-indexed 0..6 — matching the order each
city's weekly hours are listed in (Mon..Sun) — for feeding into
`weekMinute`. Falls back to Monday if the date is invalid.
-}
mondayIndexedWeekday : String -> Int
mondayIndexedWeekday isoDate =
    parseDate isoDate
        |> Maybe.map (\( year, month, day ) -> modBy 7 (sakamotoWeekday year month day + 6))
        |> Maybe.withDefault 0


dayLength : Int
dayLength =
    24 * 60


weekLength : Int
weekLength =
    7 * dayLength


{-| The conditions a run is pinned to: which day of the week it begins on
(Monday-indexed, 0..6), what time of day, how fast travel between stops
is, and how long is spent at each stop. Bundled together because they're
all snapshotted at the same moment — when a search (re)starts — so the
energy function stays fixed for the life of that search.
-}
type alias StartTime =
    { weekday : Int
    , minutes : Int
    , metersPerMinute : Float
    , stopMinutes : Int
    }


{-| `arrival` is minutes elapsed since the tour began; this converts that
into "minutes since Monday 00:00" in the repeating weekly cycle each city's
`openWindows`/`closedWindows` are expressed in.
-}
weekMinute : StartTime -> Int -> Int
weekMinute startTime arrival =
    modBy weekLength (startTime.weekday * dayLength + startTime.minutes + arrival)


{-| Minutes to wait if you arrive at a city with the given open windows
(minutes-since-Monday-00:00) at `arrival` minutes into the tour. 0 if
already open. A city with no closed windows (open 24/7) is always open.
-}
waitForCity : List ( Int, Int ) -> StartTime -> Int -> Int
waitForCity openWindows startTime arrival =
    let
        wm =
            weekMinute startTime arrival

        isOpenNow =
            List.any (\( s, e ) -> wm >= s && wm < e) openWindows
    in
    if isOpenNow then
        0

    else
        openWindows
            |> List.map (\( s, _ ) -> modBy weekLength (s - wm))
            |> List.minimum
            |> Maybe.withDefault 0



-- SOLUTION: a tour is a permutation of the 46 non-finish city indices,
-- visited in order. The first stop is wherever the route starts; `simulate`
-- appends the fixed finish (`endIndex`) as the last stop.


type alias Tour =
    List Int


{-| `departure` is `arrival + wait + stopMinutes`: the stop starts once the
restaurant is open.
-}
type alias Visit =
    { cityIndex : Int
    , arrival : Int
    , wait : Int
    , departure : Int
    }


{-| Walk the tour in order starting at `startTime` from wherever the tour
begins, carrying the clock forward leg by leg, then travel on to the fixed
finish (`endIndex`). This is why the energy function can't just sum edge
weights: whether (and how long) you wait at a city depends on the
accumulated time — and now the day of the week — when you get there, not
on the edge alone. Every stop, including the first and the finish, adds
`startTime.stopMinutes`.
-}
simulate : StartTime -> Tour -> List Visit
simulate startTime tour =
    case tour of
        [] ->
            []

        first :: rest ->
            let
                firstWait =
                    waitForCity (openWindowsFor first) startTime 0

                firstVisit =
                    { cityIndex = first, arrival = startTime.minutes, wait = firstWait, departure = startTime.minutes + firstWait + startTime.stopMinutes }

                visitCity ( prevCity, clock, visits ) cityIndex =
                    let
                        arrival =
                            clock + travelTime startTime.metersPerMinute prevCity cityIndex

                        wait =
                            waitForCity (openWindowsFor cityIndex) startTime (arrival - startTime.minutes)

                        departure =
                            arrival + wait + startTime.stopMinutes
                    in
                    ( cityIndex, departure, { cityIndex = cityIndex, arrival = arrival, wait = wait, departure = departure } :: visits )

                ( _, _, reversedVisits ) =
                    List.foldl (\c acc -> visitCity acc c) ( first, firstVisit.departure, [] ) (rest ++ [ endIndex ])
            in
            firstVisit :: List.reverse reversedVisits


openWindowsFor : Int -> List ( Int, Int )
openWindowsFor cityIndex =
    Array.get cityIndex cities |> Maybe.map .openWindows |> Maybe.withDefault [ ( 0, weekLength ) ]


totalMinutes : StartTime -> Tour -> Int
totalMinutes startTime tour =
    simulate startTime tour
        |> List.Extra.last
        |> Maybe.map (\v -> v.departure - startTime.minutes)
        |> Maybe.withDefault 0


{-| Road distance for the tour's full route (including its fixed final leg
to `endIndex`), in meters — unlike `totalMinutes`, this doesn't depend on
pace or waiting, so it's the same regardless of the run's start settings.
-}
totalDistanceMeters : Tour -> Int
totalDistanceMeters tour =
    let
        stops =
            tour ++ [ endIndex ]
    in
    List.map2 distanceBetween stops (List.drop 1 stops) |> List.sum


{-| Reverse a random contiguous segment of the visiting order — a 2-opt move
over the 46 stops before the fixed final one.
-}
twoOptNeighbor : Tour -> Random.Generator Tour
twoOptNeighbor tour =
    let
        n =
            List.length tour
    in
    Random.pair (Random.int 0 (n - 1)) (Random.int 0 (n - 1))
        |> Random.map
            (\( i, j ) ->
                let
                    lo =
                        min i j

                    hi =
                        max i j
                in
                if lo == hi then
                    tour

                else
                    let
                        ( before, rest ) =
                            List.Extra.splitAt lo tour

                        ( middle, after ) =
                            List.Extra.splitAt (hi - lo + 1) rest
                    in
                    before ++ List.reverse middle ++ after
            )


config : StartTime -> Config Tour
config startTime =
    { energy = toFloat << totalMinutes startTime
    , neighbor = twoOptNeighbor
    , temperature = Schedule.exponential { initial = 400, alpha = 0.99995 }
    , stoppingTemperature = 0.05
    }


initialTour : Tour
initialTour =
    List.range 0 (Array.length cities - 1)
        |> List.filter (\i -> i /= endIndex)



-- MODEL


type alias Model =
    { saState : State Tour
    , running : Bool
    , stepsPerFrame : Int
    , startDate : String
    , startTimeOfDay : String
    , speedInput : String
    , stopInput : String
    , seedInput : String
    , activeStart : StartTime
    , mapVisible : Bool
    , tab : Tab
    }


type Tab
    = MapTab
    | ScheduleTab


type Msg
    = Tick
    | ToggleRunning
    | Restart
    | SetStartDate String
    | SetStartTimeOfDay String
    | SetSpeedInput String
    | SetStopInput String
    | SetSeedInput String
    | ToggleMapVisible
    | SelectTab Tab


{-| (Re)starts the search from `initialTour`, snapshotting `activeStart` (see
`viewRunSettings`) and deriving the seed from `seedInput` via
`Random.initialSeed` — deterministic, so no `Cmd` round trip is needed the
way a truly random seed would require.
-}
startSearch : Model -> Model
startSearch model =
    let
        activeStart =
            { weekday = mondayIndexedWeekday model.startDate
            , minutes = parseStartMinutes model.startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile model.speedInput)
            , stopMinutes = parseStopMinutes model.stopInput
            }
    in
    { model
        | saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed model.seedInput)) initialTour
        , running = True
        , activeStart = activeStart
    }


{-| `today` is the visitor's local date as `YYYY-MM-DD`, passed in as a flag
by simulator.html, so the first run starts on the day they're looking at it.
-}
init : String -> ( Model, Cmd Msg )
init today =
    let
        speedInput =
            String.fromFloat defaultMinutesPerMile

        stopInput =
            String.fromInt defaultStopMinutes

        seedInput =
            "1"

        startDate =
            today

        startTimeOfDay =
            "06:00"

        activeStart =
            { weekday = mondayIndexedWeekday startDate
            , minutes = parseStartMinutes startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile speedInput)
            , stopMinutes = parseStopMinutes stopInput
            }
    in
    ( { saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed seedInput)) initialTour
      , running = True
      , stepsPerFrame = 1000
      , startDate = startDate
      , startTimeOfDay = startTimeOfDay
      , speedInput = speedInput
      , stopInput = stopInput
      , seedInput = seedInput
      , activeStart = activeStart
      , mapVisible = True
      , tab = MapTab
      }
    , Cmd.none
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick ->
            ( { model | saState = SimulatedAnnealing.stepN (config model.activeStart) model.stepsPerFrame model.saState }
            , Cmd.none
            )

        ToggleRunning ->
            ( { model | running = not model.running }, Cmd.none )

        Restart ->
            ( startSearch model, Cmd.none )

        SetStartDate date ->
            ( { model | startDate = date }, Cmd.none )

        SetStartTimeOfDay timeOfDay ->
            ( { model | startTimeOfDay = timeOfDay }, Cmd.none )

        SetSpeedInput speed ->
            ( { model | speedInput = speed }, Cmd.none )

        SetStopInput stop ->
            ( { model | stopInput = stop }, Cmd.none )

        SetSeedInput seed ->
            ( { model | seedInput = seed }, Cmd.none )

        ToggleMapVisible ->
            ( { model | mapVisible = not model.mapVisible }, Cmd.none )

        SelectTab tab ->
            ( { model | tab = tab }, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.running && not (SimulatedAnnealing.isDone (config model.activeStart) model.saState) then
        Browser.Events.onAnimationFrame (\_ -> Tick)

    else
        Sub.none



-- VIEW


timelineWidth : Float
timelineWidth =
    760


rowHeight : Float
rowHeight =
    34


view : Model -> Html Msg
view model =
    let
        tour =
            SimulatedAnnealing.current model.saState

        visits =
            simulate model.activeStart tour

        done =
            SimulatedAnnealing.isDone (config model.activeStart) model.saState

        viewMax =
            max 600 (((totalMinutes model.activeStart tour // 60) + 1) * 60)
    in
    Html.div [ Attr.style "font-family" "sans-serif", Attr.style "max-width" "1100px" ]
        [ viewRunSettings model
        , box "Controls"
            [ Html.button [ Events.onClick ToggleRunning, Attr.disabled done ]
                [ Html.text
                    (if done then
                        "Done"

                     else if model.running then
                        "Pause"

                     else
                        "Resume"
                    )
                ]
            , Html.button [ Events.onClick Restart ] [ Html.text "Restart" ]
            , Html.button [ Events.onClick ToggleMapVisible ]
                [ Html.text
                    (if model.mapVisible then
                        "Hide map (faster)"

                     else
                        "Show map"
                    )
                ]
            ]
        , viewTabs model.tab
            (case model.tab of
                MapTab ->
                    if model.mapVisible then
                        viewMap tour

                    else
                        Html.p [ Attr.style "color" "#666", Attr.style "margin" "0" ] [ Html.text "Map hidden." ]

                ScheduleTab ->
                    Html.div []
                        [ Html.p [ Attr.style "color" "#666", Attr.style "font-size" "0.85rem", Attr.style "margin" "0 0 0.5rem 0" ]
                            [ Html.text "Pink bands are hours a restaurant is closed. Blue bars are time spent at a restaurant. Orange bars also include waiting for it to open." ]
                        , Svg.svg
                            [ SvgAttr.width (String.fromFloat timelineWidth)
                            , SvgAttr.height (String.fromFloat (rowHeight * toFloat (List.length visits) + 10))
                            ]
                            (List.indexedMap (viewRow model.activeStart viewMax) visits |> List.concat)
                        ]
            )
        , Html.div [ Attr.style "margin-top" "0.5rem", Attr.style "display" "flex", Attr.style "gap" "1.5rem" ]
            [ readout "Iteration" (String.fromInt (SimulatedAnnealing.iteration model.saState))
            , readout "Temperature" (String.fromInt (round (SimulatedAnnealing.temperature (config model.activeStart) model.saState)))
            , readout "Current route time" (formatDuration (round (SimulatedAnnealing.currentEnergy model.saState)))
            , readout "Best route time" (formatDuration (round (SimulatedAnnealing.bestEnergy model.saState)))
            , readout "Current distance" (formatMiles (totalDistanceMeters tour))
            , readout "Best distance" (formatMiles (totalDistanceMeters (SimulatedAnnealing.best model.saState)))
            ]
        , box "Output"
            -- Disabled until there's a computed route to act on.
            [ Html.button [ Attr.disabled True ] [ Html.text "Print" ]
            , Html.button [ Attr.disabled True ] [ Html.text "Download GPX" ]
            , Html.details [ Attr.style "flex-basis" "100%" ]
                [ Html.summary [ Attr.style "cursor" "pointer", Attr.style "color" "#666" ]
                    [ Html.text "Distance matrix (meters)" ]
                , viewCostMatrix
                ]
            ]
        ]


{-| A titled group: a `<fieldset>` whose `<legend>` names it.
-}
box : String -> List (Html msg) -> Html msg
box title children =
    Html.fieldset
        [ Attr.style "border" "1px solid #999"
        , Attr.style "margin" "0.75rem 0"
        , Attr.style "padding" "0.75rem"
        , Attr.style "display" "flex"
        , Attr.style "flex-wrap" "wrap"
        , Attr.style "gap" "0.5rem 1rem"
        , Attr.style "align-items" "flex-end"
        ]
        (Html.legend [ Attr.style "font-weight" "bold", Attr.style "padding" "0 0.25rem" ] [ Html.text title ]
            :: children
        )


tabLabel : Tab -> String
tabLabel tab =
    case tab of
        MapTab ->
            "Map"

        ScheduleTab ->
            "Schedule"


tabId : Tab -> String
tabId tab =
    "simulator-tab-" ++ String.toLower (tabLabel tab)


{-| One bordered rectangle with Map/Schedule tabs along its top edge; only
the selected tab's panel is rendered, so the hidden one costs nothing per
frame.
-}
viewTabs : Tab -> Html Msg -> Html Msg
viewTabs selected panel =
    let
        viewTab tab =
            let
                isSelected =
                    tab == selected
            in
            Html.button
                [ Attr.attribute "role" "tab"
                , Attr.id (tabId tab)
                , Attr.attribute "aria-selected"
                    (if isSelected then
                        "true"

                     else
                        "false"
                    )
                , Attr.attribute "aria-controls" "simulator-tabpanel"
                , Events.onClick (SelectTab tab)
                , Attr.style "font" "inherit"
                , Attr.style "padding" "0.4rem 1rem"
                , Attr.style "margin-bottom" "-1px"
                , Attr.style "border" "1px solid #999"
                , Attr.style "border-bottom-color"
                    (if isSelected then
                        "#fff"

                     else
                        "#999"
                    )
                , Attr.style "background"
                    (if isSelected then
                        "#fff"

                     else
                        "#eee"
                    )
                , Attr.style "font-weight"
                    (if isSelected then
                        "bold"

                     else
                        "normal"
                    )
                , Attr.style "cursor" "pointer"
                ]
                [ Html.text (tabLabel tab) ]
    in
    Html.div [ Attr.style "margin" "0.75rem 0" ]
        [ Html.div [ Attr.attribute "role" "tablist", Attr.style "display" "flex", Attr.style "gap" "0.25rem", Attr.style "padding-left" "0.5rem" ]
            (List.map viewTab [ MapTab, ScheduleTab ])
        , Html.div
            [ Attr.attribute "role" "tabpanel"
            , Attr.id "simulator-tabpanel"
            , Attr.attribute "aria-labelledby" (tabId selected)
            , Attr.style "border" "1px solid #999"
            , Attr.style "background" "#fff"
            , Attr.style "padding" "0.75rem"
            ]
            [ panel ]
        ]


mapDisplayWidth : Float
mapDisplayWidth =
    300


mapDisplayHeight : Float
mapDisplayHeight =
    -- Matches data/mctrot_map.svg's viewBox aspect ratio (~1 : 3.64) at mapDisplayWidth.
    1093


{-| One space-separated `lX-lY` token per leg of the tour (the open path,
plus its fixed final leg to `endIndex`), where X and Y are real `mcd_id`s
(see `MctrotMapData.mcdIds`) in ascending order — matching the class-token
convention already baked into `MctrotMapData.routeEdges`. Setting this as an
ancestor `data-active` attribute is what lets `css/mctrot-map.css` highlight
exactly the streets the current tour uses, without Elm ever touching the
(lazy, otherwise-static) SVG subtree itself.
-}
tourEdgeTokens : Tour -> String
tourEdgeTokens tour =
    let
        stops =
            tour ++ [ endIndex ]
    in
    List.map2 pairToken stops (List.drop 1 stops)
        |> String.join " "


pairToken : Int -> Int -> String
pairToken cityIndexA cityIndexB =
    let
        mcdIdFor cityIndex =
            Array.get cityIndex MctrotMapData.mcdIds |> Maybe.withDefault 0

        a =
            mcdIdFor cityIndexA

        b =
            mcdIdFor cityIndexB
    in
    "l" ++ String.fromInt (min a b) ++ "-l" ++ String.fromInt (max a b)


{-| The borough silhouette, all 2867 real-street route segments, and the 47
location dots — built once and never touched again. `viewMap` wraps this in
`Html.Lazy.lazy` so Elm's virtual DOM skips diffing it on every animation
frame; only the wrapping `data-active` attribute actually changes per tick.
-}
viewMapStatic : () -> Html msg
viewMapStatic () =
    Svg.svg
        [ SvgAttr.viewBox MctrotMapData.mapViewBox
        , SvgAttr.width (String.fromFloat mapDisplayWidth)
        , SvgAttr.height (String.fromFloat mapDisplayHeight)
        ]
        [ Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] []
        , Svg.g []
            (MctrotMapData.routeEdges
                |> List.map (\edge -> Svg.path [ SvgAttr.class edge.classes, SvgAttr.d edge.d ] [])
            )
        , Svg.g []
            (MctrotMapData.locationCoords
                |> Array.toList
                |> List.map
                    (\( x, y ) ->
                        Svg.circle
                            [ SvgAttr.class "location"
                            , SvgAttr.cx (String.fromFloat x)
                            , SvgAttr.cy (String.fromFloat y)
                            , SvgAttr.r "150"
                            ]
                            []
                    )
            )
        ]


viewMap : Tour -> Html msg
viewMap tour =
    Html.div [ Attr.attribute "data-active" (tourEdgeTokens tour) ]
        [ Html.Lazy.lazy viewMapStatic () ]


{-| Lets you pick the conditions the next run starts under: which day of
the week (that matters now, since about a fifth of the cities have real
hours that vary by weekday), what time, and how fast travel between stops
is (as a pace in minutes/mile — the units delivery routing usually gets
quoted in — converted to meters/minute for `travelTime`), and how many
minutes are spent at each stop (see `simulate`). Editing these
fields only takes effect the next time the search (re)starts —
`activeStart` is snapshotted at that point, so nudging any of them mid-run
can't shift the energy landscape out from under an in-progress search.
-}
viewRunSettings : Model -> Html Msg
viewRunSettings model =
    box "Parameters"
        [ Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Start date" ]
            , Html.input
                [ Attr.type_ "date"
                , Attr.value model.startDate
                , Events.onInput SetStartDate
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Start time" ]
            , Html.input
                [ Attr.type_ "time"
                , Attr.value model.startTimeOfDay
                , Events.onInput SetStartTimeOfDay
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Pace (min/mile)" ]
            , Html.input
                [ Attr.type_ "number"
                , Attr.step "0.5"
                , Attr.min "0.5"
                , Attr.value model.speedInput
                , Events.onInput SetSpeedInput
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Location stop time (minutes)" ]
            , Html.input
                [ Attr.type_ "number"
                , Attr.step "1"
                , Attr.min "0"
                , Attr.value model.stopInput
                , Events.onInput SetStopInput
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Seed" ]
            , Html.input
                [ Attr.type_ "text"
                , Attr.value model.seedInput
                , Events.onInput SetSeedInput
                ]
                []
            ]
        , Html.div [ Attr.style "font-size" "0.8rem", Attr.style "color" "#666" ]
            [ Html.text
                (case weekdayName model.startDate of
                    Just day ->
                        "Starts " ++ day ++ " (changes apply on restart)"

                    Nothing ->
                        "Pick a valid date"
                )
            ]
        ]


readout : String -> String -> Html msg
readout label value =
    Html.div []
        [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text label ]
        , Html.div [ Attr.style "font-variant-numeric" "tabular-nums" ] [ Html.text value ]
        ]


xScale : Int -> Float -> Float
xScale viewMax elapsedMinutes =
    elapsedMinutes * (timelineWidth / toFloat viewMax)


viewRow : StartTime -> Int -> Int -> Visit -> List (Svg msg)
viewRow startTime viewMax rowIndex visit =
    let
        y =
            toFloat rowIndex * rowHeight

        city =
            Array.get visit.cityIndex cities |> Maybe.withDefault (City "?" [ ( 0, weekLength ) ] [])

        arrivalElapsed =
            toFloat (visit.arrival - startTime.minutes)

        departureElapsed =
            toFloat (visit.departure - startTime.minutes)

        label =
            city.name
                ++ " — arr "
                ++ formatClock visit.arrival
                ++ (if visit.wait > 0 then
                        " (waited " ++ formatDuration visit.wait ++ ")"

                    else
                        ""
                   )
    in
    [ Svg.rect
        [ SvgAttr.x "0"
        , SvgAttr.y (String.fromFloat y)
        , SvgAttr.width (String.fromFloat timelineWidth)
        , SvgAttr.height (String.fromFloat (rowHeight - 4))
        , SvgAttr.fill "#fff"
        , SvgAttr.stroke "#eee"
        ]
        []
    ]
        ++ (if not (List.isEmpty city.closedWindows) then
                closedBandsElapsed city.closedWindows startTime viewMax
                    |> List.map
                        (\( s, e ) ->
                            Svg.rect
                                [ SvgAttr.x (String.fromFloat (xScale viewMax (toFloat s)))
                                , SvgAttr.y (String.fromFloat y)
                                , SvgAttr.width (String.fromFloat (xScale viewMax (toFloat (e - s))))
                                , SvgAttr.height (String.fromFloat (rowHeight - 4))
                                , SvgAttr.fill "#fbdcdc"
                                ]
                                []
                        )

            else
                []
           )
        ++ [ Svg.rect
                [ SvgAttr.x (String.fromFloat (xScale viewMax arrivalElapsed))
                , SvgAttr.y (String.fromFloat (y + 6))
                , SvgAttr.width (String.fromFloat (max 2 (xScale viewMax (departureElapsed - arrivalElapsed))))
                , SvgAttr.height (String.fromFloat (rowHeight - 16))
                , SvgAttr.fill
                    (if visit.wait > 0 then
                        "#e8871e"

                     else
                        "#1f6feb"
                    )
                ]
                []
           , Svg.text_
                [ SvgAttr.x "4"
                , SvgAttr.y (String.fromFloat (y + rowHeight - 8))
                , SvgAttr.fontSize "11"
                , SvgAttr.fill "#333"
                ]
                [ Svg.text label ]
           ]


{-| A city's `closedWindows` (minutes-since-Monday-00:00, one repeating
week) converted to minutes-elapsed-since-the-tour-started, tiled across as
many weeks as the visible timeline (`viewMax`) spans, and clipped to
`[0, viewMax]`.
-}
closedBandsElapsed : List ( Int, Int ) -> StartTime -> Int -> List ( Int, Int )
closedBandsElapsed closedInWeek startTime viewMax =
    let
        weekOffset =
            startTime.weekday * dayLength + startTime.minutes

        maxK =
            (viewMax // weekLength) + 2
    in
    List.range 0 maxK
        |> List.concatMap
            (\k ->
                closedInWeek
                    |> List.map (\( s, e ) -> ( s - weekOffset + k * weekLength, e - weekOffset + k * weekLength ))
            )
        |> List.filterMap
            (\( s, e ) ->
                if e < 0 || s > viewMax then
                    Nothing

                else
                    Just ( max 0 s, min viewMax e )
            )


matrixCell : List (Html.Attribute msg)
matrixCell =
    [ Attr.style "border" "1px solid #ddd"
    , Attr.style "padding" "2px 6px"
    , Attr.style "text-align" "center"
    ]


distanceBetween : Int -> Int -> Int
distanceBetween from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0


viewCostMatrix : Html msg
viewCostMatrix =
    let
        cityList =
            Array.toList cities

        headerRow =
            Html.tr []
                (Html.th matrixCell [] :: List.map (\c -> Html.th matrixCell [ Html.text c.name ]) cityList)

        bodyRow i city =
            Html.tr []
                (Html.th matrixCell [ Html.text city.name ]
                    :: List.indexedMap
                        (\j _ ->
                            Html.td matrixCell
                                [ Html.text
                                    (if i == j then
                                        "—"

                                     else
                                        String.fromInt (distanceBetween i j)
                                    )
                                ]
                        )
                        cityList
                )
    in
    Html.table
        [ Attr.style "border-collapse" "collapse"
        , Attr.style "margin-top" "0.5rem"
        , Attr.style "font-size" "0.8rem"
        , Attr.style "font-variant-numeric" "tabular-nums"
        ]
        (headerRow :: List.indexedMap bodyRow cityList)


formatClock : Int -> String
formatClock absoluteMinutes =
    let
        day =
            absoluteMinutes // dayLength

        clock =
            modBy dayLength absoluteMinutes

        hh =
            clock // 60

        mm =
            modBy 60 clock

        pad n =
            String.padLeft 2 '0' (String.fromInt n)
    in
    "day " ++ String.fromInt day ++ " " ++ pad hh ++ ":" ++ pad mm


formatDuration : Int -> String
formatDuration minutes =
    String.fromInt (minutes // 60) ++ "h " ++ String.fromInt (modBy 60 minutes) ++ "m"


formatMiles : Int -> String
formatMiles meters =
    let
        tenths =
            round (toFloat meters / metersPerMile * 10)
    in
    String.fromInt (tenths // 10) ++ "." ++ String.fromInt (modBy 10 tenths) ++ " mi"


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }

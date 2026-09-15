// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Popover explaining the syntax of search result filters.
struct SearchFilterHelp: View {

    private static let sections: [(title: String, paragraphs: [String])] = [
        (String(localized: "Include Text"), [
            String(localized: "Files, folders and usernames containing this text will be shown."),
            String(localized: "Case is insensitive, but word order is important: 'Instrumental Remix' will not show any 'Remix Instrumental'"),
            String(localized: "Use | (or pipes) to seperate several exact phrases. Example:\n    Remix|Dub Mix|Instrumental")
        ]),
        (String(localized: "Exclude Text"), [
            String(localized: "As above, but files, folders and usernames are filtered out if the text matches.")
        ]),
        (String(localized: "File Type"), [
            String(localized: "Filters files based upon their file extension."),
            String(localized: "Multiple file extensions can be specified, which in turn will reveal more from the list of results. Example:\n    flac wav ape"),
            String(localized: "It is also possible to invert the filter, specifying file extensions you don't want in your results with an exclamation mark! Example:\n    !mp3 !jpg")
        ]),
        (String(localized: "File Size"), [
            String(localized: "Filters files based upon their file size."),
            String(localized: "By default, the unit used is bytes (B) and files greater than or equal to (>=) the value will be matched."),
            String(localized: "Append b, k, m, or g (alternatively kib, mib, or gib) to specify byte, kibibyte, mebibyte, or gibibyte units:\n    20m to show files larger than 20 MiB (mebibytes)."),
            String(localized: "Prepend = to a value to specify an exact match:\n    =1024 matches files that are exactly 1 KiB (kibibyte)."),
            String(localized: "Prepend ! to a value to exclude files of a specific size:\n    !30.5m to hide files that are 30.5 MiB (mebibytes)."),
            String(localized: "Prepend < or > to find files smaller/larger than the given value. Use a space between each condition to include a range:\n    >10.5m <1g to show files larger than 10.5 MiB, but smaller than 1 GiB."),
            String(localized: "The better-known variants kb, mb, and gb can also be used for kilobyte, megabyte, and gigabyte units.")
        ]),
        (String(localized: "Bitrate"), [
            String(localized: "Filters files based upon their bitrate."),
            String(localized: "Values must be entered as numeric digits only. The unit is always Kb/s (Kilobits per second)."),
            String(localized: "Like File Size (above), operators =, !, <, >, <= or >= can be used, and multiple conditions can be specified, for example to show files with a bitrate of at least 256 Kb/s with a maximum bitrate of 1411 Kb/s:\n    256 <=1411")
        ]),
        (String(localized: "Duration"), [
            String(localized: "Filters files based upon their duration."),
            String(localized: "By default, files longer than or equal to (>=) the entered duration will be matched, unless an operator (=, !, <=, < or >) is used."),
            String(localized: "Enter a raw value in seconds or use the MM:SS and HH:MM:SS time formats:\n    =53 shows files that are around 53 seconds long.\n    >5:30 to show files more than 5 and a half minutes long.\n    <5:30:00 shows files less than 5 and a half hours long."),
            String(localized: "Multiple conditions can be specified:\n    >6:00 <12:00 to show files between 6 and 12 minutes long.\n    !9:54 !8:43 !7:32 to hide some specific files from the results.\n    =5:34 =4:23 =3:05 to include files with specific durations.")
        ]),
        (String(localized: "Country"), [
            String(localized: "Filters files based upon users' geographical location according to country codes defined by ISO 3166-2:\n    US will only show results from users with IP addresses in the United States.\n    !GB will hide results that come from users in Great Britain."),
            String(localized: "Multiple countries can be specified with commas or spaces.")
        ]),
        (String(localized: "Free Slot"), [
            String(localized: "Show only those results from users which have at least one upload slot free, i.e. files that are available immediately.")
        ])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Search Result Filters"))
                    .font(.headline)

                Text(String(localized: "Search result filters are used to refine which search results are displayed."))
                Text(String(localized: "Each list of search results has its own filter which can be revealed by toggling the Result Filters button. A filter is made up of multiple fields, all of which are applied when pressing Enter in any one of its fields. Filtering is applied immediately to results already received, and also to those yet to arrive."))
                Text(String(localized: "As the name suggests, a search result filter cannot expand your original search, it can only narrow it down. To broaden or change your search terms, perform a new search."))

                Text(String(localized: "Result Filter Usage"))
                    .font(.headline)

                ForEach(Self.sections, id: \.title) { section in
                    Text(section.title)
                        .italic()

                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .padding(.leading, 12)
                    }
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
        }
        .frame(width: 500, height: 375)
    }
}

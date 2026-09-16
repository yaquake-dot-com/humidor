// SPDX-License-Identifier: GPL-3.0-or-later
//
// Credits shown in the about dialog, formatted as Markdown.

extension About {

    static let authors: [String] = [
        "**Nicotine+ Team**",
        "**Mat (mathiascode)**\n •  Maintainer (2020–present)\n •  Developer",
        "**Adam Cécile (eLvErDe)**\n •  Maintainer (2013–2016)\n •  Domain name administrator\n •  Source code migration from SVN to GitHub\n •  Developer",
        "**Han Boetes**\n •  Tester\n •  Documentation\n •  Bug hunting\n •  Translation management",
        "**alekksander**\n •  Tester\n •  Redesign of some graphics",
        "**slook**\n •  Tester\n •  Accessibility improvements",
        "**ketacat**\n •  Tester",
        "\n**Nicotine+ Team (Emeritus)**",
        "**daelstorm**\n •  Maintainer (2004–2009)\n •  Developer",
        "**quinox**\n •  Maintainer (2009–2012)\n •  Developer",
        "**Michael Labouebe (gfarmerfr)**\n •  Maintainer (2016–2017)\n •  Developer",
        "**Kip Warner**\n •  Maintainer (2018–2020)\n •  Developer\n •  Debianization",
        "**gallows (aka 'burp O')**\n •  Developer\n •  Packager\n •  Submitted Slack.Build file",
        "**hedonist (formerly known as alexbk)**\n •  OS X Nicotine.app maintainer / developer\n •  Author of PySoulSeek, used for Nicotine core",
        "**lee8oi**\n •  Bash commander\n •  New and updated /alias",
        "**INMCM**\n •  Nicotine+ topic maintainer on ubuntuforums.org",
        "**suser-guru**\n •  Suse Linux packager\n •  Nicotine+ RPM's for Suse 9.1, 9.2, 9.3, 10.0, 10.1",
        "**osiris**\n •  Handy-man\n •  Documentation\n •  Some GNU/Linux packaging\n •  Nicotine+ on Win32\n •  Author of Nicotine+ guide",
        "**Mutnick**\n •  Created Nicotine+ GitHub organization\n •  Developer",
        "**Lene Preuss**\n •  Python 3 migration\n •  Unit and DEP-8 continuous integration testing",
        "\n**Nicotine Team (Emeritus)**",
        "**Ingmar K. Steen (Hyriand)**\n •  Maintainer (2003–2004)",
        "**daelstorm**\n •  Beta tester\n •  Designer of most of the settings\n •  Made the Nicotine icons",
        "**SmackleFunky**\n •  Beta tester",
        "**Wretched**\n •  Beta tester\n •  Bringer of great ideas",
        "**(va)\\*10^3**\n •  Beta tester\n •  Designer of Nicotine homepage and artwork (logos)",
        "**sierracat**\n •  MacOSX tester\n •  soulseeX developer",
        "**Gustavo J. A. M. Carneiro**\n •  Created the exception dialog",
        "**SeeSchloss**\n •  Developer\n •  Created 1.0.8 Win32 installer\n •  Created Soulfind, open source Soulseek server written in D",
        "**vasi**\n •  Mac developer\n •  Packaged Nicotine on OSX PowerPC",
        "\n**PySoulSeek Team (Emeritus)**",
        "**Alexander Kanavin**\n •  Maintainer (2001–2003)",
        "**Nir Arbel**\n •  Helped with many protocol questions, and of course he designed and implemented the whole system",
        "**Brett W. Thompson (Zip)**\n •  His client code was used to get an initial impression of how the system works\n •  Supplied the patch for logging chat conversations",
        "**Josselin Mouette**\n •  Official Debian package maintainer",
        "**blueboy**\n •  Former unofficial Debian package maintainer",
        "**Christian Swinehart**\n •  Fink package maintainer",
        "**Ingmar K. Steen (Hyriand)**\n •  Patches for upload bandwidth management, banning, various UI improvements and more",
        "**Geert Kloosterman**\n •  A script for importing Windows Soulseek configuration",
        "**Joe Halliwell**\n •  Submitted a patch for optionally discarding search results after closing a search tab",
        "**Alexey Vyskubov**\n •  Code cleanups",
        "**Jason Green (SmackleFunky)**\n •  Ignore list and auto-join checkbox, wishlists"
    ]

    static let translators: [String] = [
        "**Albanian**\n •  W L (2023–2024)",
        "**Arabic**\n •  ButterflyOfFire (2024)",
        "**Catalan**\n •  Aniol (2024–2025)\n •  Maite Guix (2022)",
        "**Chinese (Simplified)**\n •  Ys413 (2024)\n •  Bonislaw (2023)\n •  hylau (2023)\n •  hadwin (2022)",
        "**Czech**\n •  slrslr (2024–2025)\n •  burnmail123 (2021–2023)",
        "**Danish**\n •  mathsped (2003–2004)",
        "**Dutch**\n •  Toine Rademacher (toineenzo) (2023–2024)\n •  Han Boetes (hboetes) (2021–2024)\n •  Kenny Verstraete (2009)\n •  nince78 (2007)\n •  Ingmar K. Steen (Hyriand) (2003–2004)",
        "**English**\n •  slook (2021–2024)\n •  Han Boetes (hboetes) (2021–2024)\n •  Mat (mathiascode) (2020–2024)\n •  Michael Labouebe (gfarmerfr) (2016)\n •  daelstorm (2004–2009)\n •  Ingmar K. Steen (Hyriand) (2003–2004)",
        "**Esperanto**\n •  phlostically (2021)",
        "**Estonian**\n •  rimasx (2024)\n •  PriitUring (2023)",
        "**Euskara**\n •  Julen (2006–2007)",
        "**Finnish**\n •  Kari Viittanen (Kalevi) (2006–2007)",
        "**French**\n •  Saumon (2023)\n •  subu_versus (2023)\n •  zniavre (2007–2023)\n •  Maxime Leroy (Lisapple) (2021–2022)\n •  Mohamed El Morabity (melmorabity) (2021–2024)\n •  m-balthazar (2020)\n •  Michael Labouebe (gfarmerfr) (2016–2017)\n •  Monsieur Poisson (2009–2010)\n •  ManWell (2007)\n •  systr (2006)\n •  Julien Wajsberg (flashfr) (2003–2004)",
        "**German**\n •  Han Boetes (hboetes) (2021–2024)\n •  phelissimo_ (2023)\n •  Meokater (2007)\n •  (._.) (2007)\n •  lippel (2004)\n •  Ingmar K. Steen (Hyriand) (2003–2004)",
        "**Hungarian**\n •  Szia Tomi (2022–2024)\n •  Nils (2009)\n •  David Balazs (djbaloo) (2006–2020)",
        "**Italian**\n •  Gabriele (Gabboxl) (2022–2023)\n •  ms-afk (2023)\n •  Gianluca Boiano (2020–2023)\n •  nicola (2007)\n •  dbazza (2003–2004)",
        "**Latvian**\n •  Pagal3 (2022–2025)",
        "**Lithuanian**\n •  mantas (2020)\n •  Žygimantas Beručka (2006–2009)",
        "**Norwegian Bokmål**\n •  Allan Nordhøy (comradekingu) (2021)",
        "**Polish**\n •  Mariusz (mariachini) (2017–2024)\n •  Amun-Ra (2007)\n •  thine (2007)\n •  Wojciech Owczarek (owczi) (2003–2004)",
        "**Portuguese (Brazil)**\n •  Havokdan (2022–2023)\n •  Guilherme Santos (2022)\n •  b1llso (2022)\n •  Nicolas Abril (2021)\n •  yyyyyyyan (2020)\n •  Felipe Nogaroto Gonzalez (Suicide|Solution) (2006)",
        "**Portuguese (Portugal)**\n •  ssantos (2023)\n •  Vinícius Soares (2023)",
        "**Romanian**\n •  Slendi (xslendix) (2023)",
        "**Russian**\n •  Kirill Feoktistov (SnIPeRSnIPeR) (2022–2024)\n •  Mehavoid (2021–2023)\n •  AHOHNMYC (2022)",
        "**Slovak**\n •  Jozef Říha (2006–2008)",
        "**Spanish (Chile)**\n •  MELERIX (2021–2023)\n •  tagomago (2021–2022)\n •  Strange (2021)\n •  Silvio Orta (2007)\n •  Dreslo (2003–2004)",
        "**Spanish (Spain)**\n •  gallegonovato (2023–2024)\n •  MELERIX (2021–2023)\n •  tagomago (2021–2022)\n •  Strange (2021)\n •  Silvio Orta (2007)\n •  Dreslo (2003–2004)",
        "**Swedish**\n •  mitramai (2021)\n •  Markus Magnuson (alimony) (2003–2004)",
        "**Tamil**\n •  தமிழ்நேரம் (2025)",
        "**Turkish**\n •  Oğuz Ersen (2021–2024)",
        "**Ukrainian**\n •  Oleg Gritsun (2024–2025)\n •  uniss2209 (2022)"
    ]

    static let license: [String] = [
        "Nicotine+ is licensed under the [GNU General Public License v3.0 or later](https://www.gnu.org/licenses/gpl-3.0.html), with the following exceptions:",
        "**[tinytag](https://github.com/tinytag/tinytag) licensed under the MIT License.**\nCopyright (c) 2014-2023 Tom Wallroth, Mat (mathiascode)\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: \n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.",
        "**IP2Location country data licensed under the [CC-BY-SA-4.0 License](https://creativecommons.org/licenses/by-sa/4.0/).**\nCopyright (c) 2001–2024 Hexasoft Development Sdn. Bhd.\nNicotine+ uses the IP2Location LITE database for [IP geolocation](https://lite.ip2location.com)."
    ]
}

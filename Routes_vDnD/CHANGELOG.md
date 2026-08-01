# Routes

## [v1.8.7](https://github.com/Nevcairiel/Routes/tree/v1.8.7) (2026-05-13)
[Full Changelog](https://github.com/Nevcairiel/Routes/compare/v1.8.6...v1.8.7) [Previous Releases](https://github.com/Nevcairiel/Routes/releases)

- Update TOC  
- Fix zone name collision causing data loss for identically-named zones  
    When two zones share the same localized name (e.g. Zul'Aman outdoor zone  
    and Zul'Aman dungeon instance), processMapEntries() would silently  
    overwrite Routes.LZName[name] with whichever mapID happened to be  
    iterated last by pairs(). The losing mapID's routes became unreachable  
    and plugins (GatherMate2 etc.) inserting nodes would store them under  
    the wrong mapID via the same lookup.  
    Replace the single-pass loop with a two-pass approach:  
    - Pass 1 collects all name→[id…] mappings.  
    - Collision phase builds a disambiguatedZoneNames cache keyed by uiMapID,  
      using the parent zone's localized name as the suffix (matching the  
      existing pattern for Dalaran, Shadowmoon Valley, etc.), with a numeric  
      fallback when parent names are absent or also collide.  
    - Pass 2 populates LZName using the final, unique names.  
    GetZoneName() is updated to check disambiguatedZoneNames first so that  
    Routes.GetZoneName(id) — called by plugins to convert a mapID to a name  
    before passing it to InsertNode/DeleteNode — returns the same unique  
    string that was stored in LZName.  
    Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>  
- Update interface version in Routes.toc  
    Bump TOC to 120000 on confirmation in issue #42  
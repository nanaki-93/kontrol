-- Used by make run; never force-quit, so the app's save/quit guard stays active.
on run arguments
    set appPath to item 1 of arguments
    if application appPath is running then
        with timeout of 30 seconds
            tell application appPath to quit
        end timeout

        -- Quit may be deferred or cancelled by the unsaved-work guard.
        repeat 150 times
            if not (application appPath is running) then return
            delay 0.2
        end repeat
        error "Kontrol did not quit (quit may have been cancelled or saving may need attention). No new instance was launched. Quit normally, then retry make run."
    end if
end run

--[[
 * ReaScript Name:  1-sided warp (accelerate) selected events in lane under mouse.
 * Description:  A simple script for warping the positions of MIDI events.
 *               The script only affects events in the MIDI editor lane under the mouse cursor.
 *               NB: Useful for changing a linear ramp into a parabolic (or other power) curve.
 *               NB: Useful for accelerating a series of evenly spaced notes.
 * Instructions:  The script must be linked to a shortcut key.  
 *                To use, 1) select MIDI events to be stretched,  
 *                        2) position mouse in lane, 
 *                        3) press shortcut key, and
 *                        4) move mouse left or right to warp to the corresponding side.
 *                        5) To exit, move mouse out of CC lane, or press shortcut key again.
 * Screenshot: 
 * Notes: 
 * Category: 
 * Author: juliansader
 * Licence: GPL v3
 * Forum Thread: 
 * Forum Thread URL: http://forum.cockos.com/showthread.php?t=176878
 * Version: 1.0
 * REAPER: 5.20
 * Extensions: SWS/S&M 2.8.3
]]
 

--[[
 Changelog:
 * v1.0 (2016-05-15)
    + Initial Release
]]

local editor, take, window, segment, details, test, newDetails,
      mouseLane, mouseStartTime, mouseStartPPQpos,
      eventIndex, eventType, eventPPQpos, msg1, msg2, msg, 
      newPPQpos, mouseDirection, mouseMovement, mouseNewPPQpos, newMouseLane,
      firstPPQpos, lastPPQpos, eventsPPQrange

editor = reaper.MIDIEditor_GetActive()
take = reaper.MIDIEditor_GetTake(editor)
window, segment, details = reaper.BR_GetMouseCursorContext()

-- Mouse must be positioned in CC lane
if details ~= "cc_lane" then return(0) end

-- ! SWS documentation is incorrect: NO retval is returned
-- ! by BR_GetMouseCursorContext_MIDI()
-- The 'type' of the second variable returned can perhaps distinguish between 
--     versions of this function.
_, test, mouseLane, _, _ = reaper.BR_GetMouseCursorContext_MIDI() 
if type(test) == boolean then
    reaper.ShowConsoleMsg("Error: Probably incompatible SWS version")
    return(0)
end

mouseStartTime = reaper.BR_GetMouseCursorContext_Position()
mouseStartPPQpos = reaper.MIDI_GetPPQPosFromProjTime(take, mouseStartTime)

--------------------------------------------------------------------
-- Find events in mouse lane.
-- sysex and text events are weird, so use different "Get" function

-- mouseLane = "CC lane under mouse cursor (CC0-127=CC, 0x100|(0-31)=14-bit CC, 
-- 0x200=velocity, 0x201=pitch, 0x202=program, 0x203=channel pressure, 
-- 0x204=bank/program select, 0x205=text, 0x206=sysex, 0x207=off velocity)"

local events = {} -- All selected events in lane will be stored in an array

if mouseLane == 0x206 or mouseLane == 0x205 -- sysex and text events
    then
    eventIndex = reaper.MIDI_EnumSelTextSysexEvts(take, -1)
    while(eventIndex ~= -1) do
        _, _, _, eventPPQpos, eventType, msg = reaper.MIDI_GetTextSysexEvt(take, eventIndex)
        if (mouseLane == 0x206 and eventType == -1) -- only sysex
        or (mouseLane == 0x205 and eventType ~= -1) -- only text events
            then
            table.insert(events, {index = eventIndex, 
                                  PPQ = eventPPQpos, 
                                  msg = msg, 
                                  type = 0xF})
        end
        eventIndex = reaper.MIDI_EnumSelTextSysexEvts(take, eventIndex)
    end

else  -- all other event types that are not sysex or text

    eventIndex = reaper.MIDI_EnumSelEvts(take, -1)
    while(eventIndex ~= -1) do   
        _, _, _, eventPPQpos, msg = reaper.MIDI_GetEvt(take, eventIndex, true, true, 0, "")
        msg1=tonumber(string.byte(msg:sub(1,1)))
        msg2=tonumber(string.byte(msg:sub(2,2)))
        eventType = msg1>>4

        -- Now, select only event types that correspond to mouseLane:
        if (0 <= mouseLane and mouseLane <= 127 -- CC, 7 bit (single lane)
            and msg2 == mouseLane and eventType == 11)
        or (256 <= mouseLane and mouseLane <= 287 -- CC, 14 bit (double lane)
            and (msg2 == mouseLane-256 or msg2 == mouseLane-224) and eventType ==11) -- event can be from either MSB or LSB lane
        or ((mouseLane == 0x200 or mouseLane == 0x207) -- Velocity or off-velocity
            and (eventType == 9 or eventType == 8)) -- note on or note off
        or (mouseLane == 0x201 and eventType == 14) -- pitch
        or (mouseLane == 0x202 and eventType == 12) -- program select
        or (mouseLane == 0x203 and eventType == 13) -- channel pressure (after-touch)
        or (mouseLane == 0x204 and eventType == 12) -- Bank/Program select - Program select
        or (mouseLane == 0x204 and eventType == 11 and msg2 == 0) -- Bank/Program select - Bank select MSB
        or (mouseLane == 0x204 and eventType == 11 and msg2 == 32) -- Bank/Program select - Bank select LSB
        then
            table.insert(events, {index = eventIndex, 
                                  PPQ = eventPPQpos, 
                                  msg = msg, 
                                  type = eventType})
        end
        eventIndex = reaper.MIDI_EnumSelEvts(take, eventIndex)
    end
end    

--------------------------------------------------------------
-- If only two event are selected, there is nothing to warp
if (#events < 3)
or (256 <= mouseLane and mouseLane <= 287 and #events < 6)
or (mouseLane == 0x204 and #events < 6)
    then return(0) 
end

------------------------------------
-- Find first and last PPQ of events
tempFirstPPQ = events[1].PPQ
tempLastPPQ = events[1].PPQ
for i=1, #events do
    if events[i].PPQ < tempFirstPPQ then tempFirstPPQ = events[i].PPQ
    elseif events[i].PPQ > tempLastPPQ then tempLastPPQ = events[i].PPQ
    end
end
firstPPQpos = tempFirstPPQ
lastPPQpos = tempLastPPQ
eventsPPQrange = lastPPQpos - firstPPQpos

---------------------------------------------------------------------------
-- Finally, here is the warping function that will be looped by 'deferring'

function loop_warp()
    _, _, newDetails = reaper.BR_GetMouseCursorContext()
    _, _, newMouseLane, ccLaneVal, _ = reaper.BR_GetMouseCursorContext_MIDI()
    -- Function exits if mouse is moved out of CC lane
    if newDetails ~= "cc_lane" or newMouseLane ~= mouseLane or ccLaneVal == -1 then
        return(0)
    end
    
    mouseNewTime = reaper.BR_GetMouseCursorContext_Position()
    mouseNewPPQpos = reaper.MIDI_GetPPQPosFromProjTime(take, mouseNewTime)
    
    -- The warping uses a power function, and the power variable is determined
    --     by calculating to what power 0.5 must be raised to reach the 
    --     mouse's deviation to the left or right fro its starting PPQ position. 
    -- The PPQ range of the selected events is used as reference to calculate
    --     magnitude of mouse movement.
    -- Why use absolute value?  Since power>1 gives a nicer, more 'musical looking'
    --     shape than power<1.
    mouseDirection = mouseNewPPQpos-mouseStartPPQpos -- Positive if moved to right, negative if moved to left
    mouseMovement = 0.5 + math.abs(mouseDirection/eventsPPQrange)
    -- Prevent warping too much, so that all CCs don't end up in a solid block
    if mouseMovement > 0.99 then mouseMovement = 0.99 end
    power = math.log(mouseMovement, 0.5)
      
    for i=1, #events do
	if mouseDirection == 0 then
	    newPPQpos = events[i].PPQ
	elseif mouseDirection < 0 then
	    newPPQpos = lastPPQpos - (((lastPPQpos - events[i].PPQ)/eventsPPQrange)^power)*eventsPPQrange -- add 0.5 to simulate rounding            
	else -- mouseDirection > 0
	    newPPQpos = firstPPQpos + (((events[i].PPQ - firstPPQpos)/eventsPPQrange)^power)*eventsPPQrange -- add 0.5 to simulate rounding
	end
	
	if mouseLane == 0x205 or mouseLane == 0x206 then
	    reaper.MIDI_SetTextSysexEvt(take, events[i].index, nil, nil, newPPQpos, nil, events[i].msg, true)
	else    
	    reaper.MIDI_SetEvt(take, events[i].index, nil, nil, newPPQpos, events[i].msg, true) -- Strange: according to the documentation, msg is optional
	end
    end
            
    -- Loop the function continuously
    reaper.defer(loop_warp)

end -- function loop_warp()

-----------------------------------------------------------------------

function exit()
    reaper.MIDI_Sort(take)
    if mouseLane == 0x206 then
        undoString = "1-sided warp (accelerate) MIDI events: Sysex"
    elseif mouseLane == 0x205 then
        undoString = "1-sided warp (accelerate) MIDI events: Text events"
    elseif 0 <= mouseLane and mouseLane <= 127 then -- CC, 7 bit (single lane)
        undoString = "1-sided warp (accelerate) MIDI events: 7 bit CC, lane ".. tostring(mouseLane)
    elseif 256 <= mouseLane and mouseLane <= 287 then -- CC, 14 bit (double lane)
        undoString = "1-sided warp (accelerate) MIDI events: 14 bit CC, lanes ".. tostring(mouseLane-256) .. "/" .. tostring(mouseLane-224)
    elseif mouseLane == 0x200 or mouseLane == 0x207 then -- Velocity or off-velocity
        undoString = "1-sided warp (accelerate) MIDI events: Notes"
    elseif mouseLane == 0x201 then -- pitch
        undoString = "1-sided warp (accelerate) MIDI events: Pitchwheel"
    elseif mouseLane == 0x202 then -- program select
        undoString = "1-sided warp (accelerate) MIDI events: Program Select"
    elseif mouseLane == 0x203 then -- channel pressure (after-touch)
        undoString = "1-sided warp (accelerate) MIDI events: Channel Pressure"
    elseif mouseLane == 0x204 then -- Bank/Program select - Program select
        undoString = "1-sided warp (accelerate) MIDI events: Bank/Program Select"
    else              
        undoString = "1-sided warp (accelerate) MIDI events"
    end -- if mouseLane ==
    
    reaper.Undo_OnStateChange(undoString, -1)
end

reaper.atexit(exit)

loop_warp()

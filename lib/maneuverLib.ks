@LAZYGLOBAL off.

// #EXTERNAL_IDS maneuverLib, timeLib, schedulingLib, asyncLib
// import libraries
runoncepath("/lib/timeLib").
runoncepath("/lib/schedulingLib").
runoncepath("/lib/asyncLib").
runoncepath("/lib/utilsLib").
runoncepath("/lib/rcsLib").
runoncepath("/lib/vectorLib").
runoncepath("/lib/translationLib").

global maneuverLib to ({
    local function getCircularization {
        parameter UT.

        local pos to (positionat(ship, UT) - body:position).
        local vel to (velocityat(ship, UT):orbit).

        local speed to sqrt(body:mu / pos:mag).
        local desiredVel to vxcl(pos, vel):normalized * speed.

        return desiredVel - vel.
    }

    local function execNode {
        parameter shipIsp, shipThrust, shipMass.

        if hasnode {
            local theNode to nextnode.
            execManeuver(theNode:time, theNode:burnVector, shipIsp, shipThrust, shipMass).
        }
    }

    local function execNodeAsync {
        parameter shipIsp, shipThrust, shipMass.

        if hasnode {
            local theNode to nextnode.
            return execManeuverAsync(theNode:time, theNode:burnVector, shipIsp, shipThrust, shipMass).
        }
    }

    local function fineTuneNode {
        parameter maxError is 1e-3.

        if hasnode {
            local theNode to nextnode.
            local getVelocityError to {
                return theNode:deltav.
            }.
            local stopCondition to {
                return theNode:deltav:mag < maxError.
            }.
            rcs on.
            translationLib:cancelVelocityError(getVelocityError, stopCondition).
            rcs off.
        }
    }

    local function execManeuver {
        parameter UT, burnVector, shipIsp, shipThrust, shipMass.

        local burnVectorUT to time:seconds.
        local info to execManeuverInfo(UT, burnVector:mag, shipIsp, shipThrust, shipMass).
        local throttleLevel to info:thrust / shipThrust.
        local startTime to info:startTime - 0.02.   // account for engine spin-up delay

        sas off.

        // compensate for the frame of reference rotation
        if altitude < 100e3 {
            local fixRotFunc to utilsLib:getFixRotFunction().
            lock steering to lookdirup(fixRotFunc(time:seconds, burnVectorUT) * burnVector, facing:topvector).
        }
        else {
            lock steering to lookdirup(burnVector, facing:topvector).
        }
        
        wait until abs(time:seconds - startTime) < 0.005.
        lock throttle to throttleLevel.

        wait until abs(time:seconds - info:endTime) < 0.005.
        lock throttle to 0.
        unlock steering.
        sas on.
    }

    local function execManeuverAsync {
        parameter UT, burnVector, shipIsp, shipThrust, shipMass.

        local burnVectorUT to time:seconds.
        local info to execManeuverInfo(UT, burnVector:mag, shipIsp, shipThrust, shipMass).
        local throttleLevel to info:thrust / shipThrust.
        local startTime to info:startTime - 0.02.   // account for engine spin-up delay
        local doneFlag to false.

        local sched to schedulingLib:eventScheduler().
        sched:addEvent(max(time:seconds, startTime-20), {
            sas off.
            if altitude < 100e3 {
                local fixRotFunc to utilsLib:getFixRotFunction().
                lock steering to lookdirup(fixRotFunc(time:seconds, burnVectorUT) * burnVector, facing:topvector).
            }
            else {
                lock steering to lookdirup(burnVector, facing:topvector).
            }
        }).
        sched:addEvent(startTime, { lock throttle to throttleLevel. }).
        sched:addEvent(info:endTime, { 
            lock throttle to 0.
            unlock steering.
            sas on.
            set doneFlag to true.
        }).

        return asyncLib:newTask({ return doneFlag. }).
    }

    local function execManeuverRCS {
        parameter UT, burnVector, shipIsp, shipThrust, shipMass.

        // set the RCS deadband to zero
        rcsLib:setDeadband(0).

        // assume symmetric thrust in each axis
        local rcsThrust to rcsLib:getTotalThrustList()[1].
        local minThrust to min(rcsThrust:X, min(rcsThrust:Y, rcsThrust:Z)).
        local rcsThrustCoef to minThrust * vectorLib:inverse(rcsThrust).

        local translationVector to -facing * burnVector:normalized.
        // deform the translation vector depending on the thrust available on each axis
        set translationVector to vectorLib:elementWiseProduct(translationVector, rcsThrustCoef).
        // calculate the thrust and isp accounting for thrusters firing at an angle
        local activeThrust to vectorLib:elementWiseProduct(translationVector, rcsThrust).
        set shipIsp to shipIsp * (activeThrust:mag / (abs(activeThrust:X) + abs(activeThrust:Y) + abs(activeThrust:Z))).
        set shipThrust to activeThrust:mag.
        local info to execManeuverInfo(UT, burnVector:mag, shipIsp, shipThrust, shipMass).

        // reduce the translation vector to match the calculated thrust
        set translationVector to translationVector * (info:thrust / shipThrust).

        // RCS thrusters take three ticks to spin-up and one tick to spin-down
        local startTime to info:startTime - 0.06.
        local endTime to info:endTime - 0.02.

        wait until abs(time:seconds - startTime) < 0.005.
        set ship:control:translation to translationVector.

        wait until abs(time:seconds - endTime) < 0.005.
        set ship:control:translation to V(0,0,0).
    }

    local function execManeuverInfo {
        parameter UT, dV, shipIsp, shipThrust, shipMass.

        // adjust thrust level to ensure the burn time is longer than 1s.
        local totalBurnTime to 0.
        local minBurnTime to 2.
        until totalBurnTime >= minBurnTime {
            set totalBurnTime to burnTimeFromThrust(dV, shipIsp, shipThrust, shipMass).
            if totalBurnTime < minBurnTime {
                set shipThrust to shipThrust / (minBurnTime / totalBurnTime).
            }
        }
        // adjust thrust level to ensure the burn time is a multiple of 0.02
        local alignedTotalBurnTime to timeLib:alignOffset(totalBurnTime).
        set totalBurnTime to alignedTotalBurnTime + (choose 0.02 if alignedTotalBurnTime < totalBurnTime else 0).
        set shipThrust to thrustFromBurnTime(dV, shipIsp, totalBurnTime, shipMass).
        // calculate the start time to burn around half the dv before and after the UT
        local burnStartTime to burnTimeFromThrust(dV/2, shipIsp, shipThrust, shipMass).
        set burnStartTime to UT - timeLib:alignOffset(burnStartTime).
        local burnEndTime to burnStartTime + totalBurnTime.

        return lex(
            "startTime", burnStartTime,
            "endTime", burnEndTime,
            "thrust", shipThrust,
            "time", totalBurnTime
        ).
    }

    local function burnTimeFromThrust {
        parameter dV, shipIsp, shipThrust, shipMass.
        return burnInfoFromThrust(dV, shipIsp, shipThrust, shipMass):burnTime.
    }

    local function burnInfoFromThrust {
        parameter dV, shipIsp, shipThrust, shipMass.

        local Ispg to shipIsp * constant:g0.
        local finalMass to shipMass / (constant:e^(dV / Ispg)).
        local massFlowRate to shipThrust / Ispg.
        local burnTime to (shipMass - finalMass) / massFlowRate.

        return lex(
            "burnTime", burnTime,
            "finalMass", finalMass,
            "massFlowRate", massFlowRate
        ).
    }

    local function thrustFromBurnTime {
        parameter dV, shipIsp, burnTime, shipMass.
        
        local Ispg to shipIsp * constant:g0.
        local finalMass to shipMass / (constant:e^(dV / Ispg)).
        local shipThrust to ((shipMass - finalMass) * Ispg) / burnTime.

        return shipThrust.
    }

    return lexicon(
        "getCircularization", getCircularization@,
        "execNode", execNode@,
        "execNodeAsync", execNodeAsync@,
        "fineTuneNode", fineTuneNode@,
        "execManeuver", execManeuver@,
        "execManeuverAsync", execManeuverAsync@,
        "execManeuverRCS", execManeuverRCS@,
        "execManeuverInfo", execManeuverInfo@,
        "burnTimeFromThrust", burnTimeFromThrust@,
        "burnInfoFromThrust", burnInfoFromThrust@,
        "thrustFromBurnTime", thrustFromBurnTime@
    ).
}):call().
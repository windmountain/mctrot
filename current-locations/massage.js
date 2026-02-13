import fs from 'fs';

const downtownFile = fs.readFileSync('downtown-results.json')
const uptownFile = fs.readFileSync('uptown-results.json')

const downtown = JSON.parse(downtownFile)
const uptown = JSON.parse(uptownFile)
const locations = [...uptown.features, ...downtown.features]

const addLocationToMap = (memo, location) =>
  memo.set(location.properties.id, location)

const toFeature = (location) => {
  return {
    "type": "Feature",
    "geometry": {
      "type": "Point",
      "coordinates": location.geometry.coordinates
    },
    "properties": {
      "shortDescription": location.properties.shortDescription,
      "longDescription": location.properties.longDescription,
      "id": location.properties.id,
      "hasIndoorDining": location.properties.filterType.includes("INDOORDINING"),
      "isTwentyFourHours": location.properties.filterType.includes("TWENTYFOURHOURS"),
      "addressLine1": location.properties.addressLine1,
      "addressLine2": location.properties.addressLine2,
      "addressLine3": location.properties.addressLine3,
      "addressLine4": location.properties.addressLine4,
      "subDivision": location.properties.subDivision,
      "postcode": location.properties.postcode,
      "customAddress": location.properties.customAddress,
      "telephone": location.properties.telephone,
      "restaurantHoursMonday":    location.properties.restauranthours?.hoursMonday,
      "restaurantHoursTuesday":   location.properties.restauranthours?.hoursTuesday,
      "restaurantHoursWednesday": location.properties.restauranthours?.hoursWednesday,
      "restaurantHoursThursday":  location.properties.restauranthours?.hoursThursday,
      "restaurantHoursFriday":    location.properties.restauranthours?.hoursFriday,
      "restaurantHoursSaturday":  location.properties.restauranthours?.hoursSaturday,
      "restaurantHoursSunday":    location.properties.restauranthours?.hoursMonday,
      "nationalStoreNumber": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "NATLSTRNUMBER")["identifierValue"],
      "entityId": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "Entity")["identifierValue"],
      "regionId": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "Region ID")["identifierValue"],
      "coOp": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "Co-Op")["identifierValue"],
      "coOpId": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "Co-Op ID")["identifierValue"],
      "CoOpName": location.properties.identifiers.storeIdentifier
        .find((i) => i.identifierType == "Co-Op Name")["identifierValue"],
      "driveThru": Boolean(location.properties.driveThru),
      "outDoorPlayGround": Boolean(location.properties.outDoorPlayGround),
      "indoorPlayGround": Boolean(location.properties.indoorPlayGround),
      "breakfast": Boolean(location.properties.breakfast),
      "nightMenu": Boolean(location.properties.nightMenu),
      "timeZone": location.properties.timeZone
    }
  }
}

const mcMap = Array.from(
    locations
      .reduce(addLocationToMap, new Map())
      .values()
  )
  .map(toFeature)

const featureCollection = {
  type: "FeatureCollection",
  features: mcMap
}

console.log(JSON.stringify(featureCollection, null, 2));

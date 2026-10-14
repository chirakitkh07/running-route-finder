const RouteRepository = require('../repositories/routeRepository');

/**
 * Route Service - Handles routing via OpenStreetMap (OSRM) and DB operations for routes
 */
class RouteService {
  // OSRM public demo server (for development only)
  static BASE_URL = 'https://router.project-osrm.org';

  /**
   * Get walking/running route between two points
   * @param {number} startLat - Start latitude
   * @param {number} startLng - Start longitude
   * @param {number} endLat - End latitude
   * @param {number} endLng - End longitude
   * @returns {Object} Route data with distance, duration, and geometry
   */
  static async getRoute(startLat, startLng, endLat, endLng) {
    try {
      // OSRM uses lng,lat order (not lat,lng)
      const coordinates = `${startLng},${startLat};${endLng},${endLat}`;
      const url = `${RouteService.BASE_URL}/route/v1/foot/${coordinates}?overview=full&geometries=geojson&steps=true`;

      const response = await fetch(url);
      if (!response.ok) throw new Error('OSRM routing failed');

      const data = await response.json();

      if (data.code !== 'Ok' || !data.routes || data.routes.length === 0) {
        throw new Error('No route found');
      }

      const route = data.routes[0];
      return {
        distanceKm: (route.distance / 1000).toFixed(2),
        durationMinutes: Math.round(route.duration / 60),
        geometry: route.geometry, // GeoJSON LineString
        steps: route.legs[0].steps.map(step => ({
          instruction: step.maneuver.type,
          distance: step.distance,
          duration: step.duration,
          name: step.name || 'unnamed road',
        })),
      };
    } catch (error) {
      console.error('RouteService Error:', error);
      throw new Error('RouteService Error: ' + error.message);
    }
  }

  /**
   * Get route passing through multiple waypoints
   * @param {Array} waypoints - Array of {lat, lng} objects
   * @returns {Object} Route data
   */
  static async getMultiPointRoute(waypoints) {
    try {
      if (!waypoints || waypoints.length < 2) {
        throw new Error('At least 2 waypoints required');
      }

      const coordinates = waypoints
        .map(wp => `${wp.lng},${wp.lat}`)
        .join(';');

      const url = `${RouteService.BASE_URL}/route/v1/foot/${coordinates}?overview=full&geometries=geojson&steps=true`;

      const response = await fetch(url);
      if (!response.ok) throw new Error('OSRM routing failed');

      const data = await response.json();

      if (data.code !== 'Ok' || !data.routes || data.routes.length === 0) {
        throw new Error('No route found');
      }

      const route = data.routes[0];
      return {
        distanceKm: (route.distance / 1000).toFixed(2),
        durationMinutes: Math.round(route.duration / 60),
        geometry: route.geometry,
        legs: route.legs.map((leg, i) => ({
          from: waypoints[i],
          to: waypoints[i + 1],
          distanceKm: (leg.distance / 1000).toFixed(2),
          durationMinutes: Math.round(leg.duration / 60),
        })),
      };
    } catch (error) {
      console.error('RouteService Error:', error);
      throw new Error('RouteService Error: ' + error.message);
    }
  }

  /**
   * Save a user route using the unified Repository
   * @param {Object} routeData
   */
  static async saveRoute(routeData) {
    if (!routeData.userId || !routeData.coordinates) {
      throw new Error('Missing userId or coordinates');
    }
    return await RouteRepository.saveRoute(routeData);
  }

  /**
   * Fetch all saved routes for a single user
   * @param {string} userId
   */
  static async getUserRoutes(userId) {
    if (!userId) {
      throw new Error('UserId is required');
    }
    return await RouteRepository.getRoutesByUser(userId);
  }
}

module.exports = RouteService;

const RouteService = require('../services/routeService');

exports.saveRoute = async (req, res) => {
  try {
    const routeData = req.body;
    const newRoute = await RouteService.saveRoute(routeData);
    res.status(201).json(newRoute);
  } catch (error) {
    if (error.message.includes('Missing userId or coordinates')) {
      return res.status(400).json({ error: error.message });
    }
    res.status(500).json({ error: error.message });
  }
};

exports.getUserRoutes = async (req, res) => {
  try {
    const { userId } = req.params;
    const routes = await RouteService.getUserRoutes(userId);
    res.status(200).json(routes);
  } catch (error) {
    if (error.message.includes('UserId is required')) {
      return res.status(400).json({ error: error.message });
    }
    res.status(500).json({ error: error.message });
  }
};

/**
 * Calculate route between two points using OSRM
 * GET /api/routes/calculate?startLat=18.79&startLng=98.98&endLat=18.80&endLng=98.99
 */
exports.calculateRoute = async (req, res) => {
  try {
    const { startLat, startLng, endLat, endLng } = req.query;

    if (!startLat || !startLng || !endLat || !endLng) {
      return res.status(400).json({ error: 'Missing startLat, startLng, endLat, or endLng' });
    }

    const route = await RouteService.getRoute(
      parseFloat(startLat),
      parseFloat(startLng),
      parseFloat(endLat),
      parseFloat(endLng)
    );

    res.status(200).json(route);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

/**
 * Calculate route through multiple waypoints
 * POST /api/routes/calculate-multi
 * Body: { waypoints: [{lat, lng}, {lat, lng}, ...] }
 */
exports.calculateMultiRoute = async (req, res) => {
  try {
    const { waypoints } = req.body;

    if (!waypoints || !Array.isArray(waypoints) || waypoints.length < 2) {
      return res.status(400).json({ error: 'At least 2 waypoints required' });
    }

    const route = await RouteService.getMultiPointRoute(waypoints);
    res.status(200).json(route);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
};

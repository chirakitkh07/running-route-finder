const express = require('express');
const router = express.Router();
const routeController = require('../controllers/routeController');

// GET saved routes for a user
router.get('/user/:userId', routeController.getUserRoutes);

// POST save a new route
router.post('/', routeController.saveRoute);

// GET calculate route between two points (OSRM)
router.get('/calculate', routeController.calculateRoute);

// POST calculate route through multiple waypoints (OSRM)
router.post('/calculate-multi', routeController.calculateMultiRoute);

module.exports = router;

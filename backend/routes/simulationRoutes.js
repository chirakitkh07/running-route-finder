const express = require('express');
const router = express.Router();
const simulationController = require('../controllers/simulationController');

// GET pre-run simulation
router.get('/pre-run', simulationController.simulatePreRun);

module.exports = router;

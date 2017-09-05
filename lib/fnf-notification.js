'use strict';

const config = require('./config');
const redis = require('./cache');
const NOTIFICATION_ENABLED = config.get('NOTIFICATION_ENABLED');
const NOTIFICATION_EVENT = config.get('NOTIFICATION_EVENT');
const NOTIFICATION_TASK = config.get('NOTIFICATION_TASK');
const desiredEvents = config.get('NOTIFICATION_EVENT_TYPES').split(',');

module.exports = {
	notifyEvent: function (deviceId, events, parameters) {
		if (!NOTIFICATION_ENABLED) {
			return;
		}
		events = events || [];
		var matchingEvents = events.filter(function (event) {
			event = event.trim();
			return desiredEvents.indexOf(event) >= 0;
		});

		if (matchingEvents.length) {
			return redis.publish(NOTIFICATION_EVENT, JSON.stringify({
				deviceId: deviceId,
				events: matchingEvents,
				parameters: parameters
			}));
		}
	},

	notifyTask: function (taskId, event) {
		if (!NOTIFICATION_ENABLED) {
			return;
		}
		return redis.publish(NOTIFICATION_TASK, JSON.stringify({
			taskId: taskId,
			error: event.error,
			message: event.message,
			task: event.task
		}));
	}
};
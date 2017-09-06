'use strict;'

const config = require('../lib/config');

console.log(config.get('REDIS'));

const cache = require('../lib/cache');

cache.connect(function() {
	console.log(123)
})
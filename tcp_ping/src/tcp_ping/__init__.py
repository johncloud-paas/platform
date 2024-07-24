# -*- coding: utf-8 -*-
"""

.. include:: ../../README.md

# Testing

## Run the tests

To run tests, just run:

    pdm run pytest

## Test reports

[See test report](../tests/report.html)



[See coverage](../coverage/index.html)

.. include:: ../../CHANGELOG.md

"""
import os
import logging

from rich.logging import RichHandler


# création de l'objet logger qui va nous servir à écrire dans les logs
logger = logging.getLogger("tcp_ping_logger")
logger.setLevel(os.environ.get("LOGLEVEL", "INFO").upper())

stream_handler = RichHandler()
logger.addHandler(stream_handler)

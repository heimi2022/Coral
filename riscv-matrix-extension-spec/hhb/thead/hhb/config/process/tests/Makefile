# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
CC = gcc
CFLAGES = -O0 -g3
CFLAGES += -I../include -I../../jpeg-9d
CFLAGES += -I../../libpng-1.6.37/
CFLAGES += -I../../zlib-1.2.11
LDFLAGS = ../../jpeg-9d/build/liblibjpeg.a -lm
LDFLAGS += ../../libpng-1.6.37/build/libpng.a
LDFLAGS += ../../zlib-1.2.11/build/libz.a

.PYONY : all clean
all : test_main_op

test_main_op : test_main_op.o process.o
	${CC} ${CFLAGES} -o $@ $^ ${LDFLAGS}

test_main_op.o : test_main_op.c
	${CC} -c ${CFLAGES} -o $@ $^

process.o : ../src/process.c
	${CC} -c ${CFLAGES} -o $@ $^

clean :
	rm test_main_op test_main_op.o process.o

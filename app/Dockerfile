FROM public.ecr.aws/lambda/python:3.13

COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

COPY VERSION ${LAMBDA_TASK_ROOT}/
COPY geoloader ${LAMBDA_TASK_ROOT}/geoloader

CMD ["geoloader.handler.handler"]

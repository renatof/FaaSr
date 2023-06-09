# using Tidyverse style guide - https://style.tidyverse.org/index.html

# The package implements the following functions:
# faasr_start - start the execution of the function; takes a JSON string as argument
# faasr_parse - parse the JSON payload, returns a parsed list if payload validation is successful
# faasr_get_user_function_args - extract user function arguments from parsed list
# faasr_put_file - put a file from local storage to S3
# faasr_get_file - get a file from S3 to local storage
# faasr_log - append to a log file stored in S3
# faasr_trigger - generate trigger(s) for any additional user-specified actions

library("jsonlite")
library("jsonvalidate")
library("aws.s3")
library("RCurl")
library("httr")
library("uuid")
# AWS SDK
library("paws")

# faasr_start is the function that starts execution of the user-supplied function
# faasr_start is the entry point invoked by the FaaS platform (e.g. OpenWhisk, Lambda, GH Actions) when a container starts
# faasr_payload is a JSON file payload containing all configuration key/value pairs for this invocation
faasr_start <- function(faasr_payload) {
  # First, call faasr_parse to validate the JSON payload, return parsed list
  faasr <- faasr_parse(faasr_payload)

  # TBD first, need to check for parsing error and schema compliance and return if there's an error parsing/validating the JSON file
  
  # TBD second, need to check if the log server is correctly configured, otherwise return an error
  
  # TBD third, need to check if the rest of the JSON payload is correctly configured - for anything incorrect, use faasr_log to log to S3, and then return an error
  
  # TBD fourth, need to check if there are no invocation cycles

  # Make a DAG and Check whether it has errors e.g., infinite loop
  graph<-faasr_check_workflow_cycle(faasr)
  # Make a list of predecessor of this function
  pre<-faasr_predecessors_list(faasr, graph)
  # Check that this function should "wait" or "proceed", which has more than 2 predecessors. 
  faasr_check(faasr, pre)

  # Now extract the name of the user-provided function to invoke
  user_function = get(faasr$FunctionInvoke)
  
  # Invoke the user function, passing the parsed list as argument
  faasr_result <- user_function(faasr)
  
  # mark the function invoked as "done"
  # Check if directory already exists. If not, create one
  log_folder<-paste0("FaaSrLogs/",faasr$InvocationID)
  if (!dir.exists(log_folder)){dir.create(log_folder, recursive=TRUE)}
  # file name would be "Functionname.done"
  file_name <- paste0(faasr$FunctionInvoke, ".done")
  # Create a file named "Functionname.done" with the content string "TRUE"
  write.table("TRUE", file=paste0(log_folder, "/", file_name), row.names=F, col.names=F)
  # Put it into the LoggingServer(DataStore Server)
  faasr_put_file(faasr, faasr$LoggingServer, log_folder, file_name, log_folder, file_name)	
	
  # Now trigger the next actions(s) if any
  faasr_trigger(faasr)

  #
  cat('{\"msg\":\"Invocation ID is',faasr$InvocationID,'\"}', "\n")
}

# faasr_parse is the function that parses and validates the JSON payload containing all configuration key/value pairs for this invocation
faasr_parse <- function(faasr_payload) {
  # First, attempt to read JSON
	
  # Room for the different way
  # url <- "https://raw.githubusercontent.com/renatof/FaaSr/main/schema/FaaSr.schema.json"
  # faasr_schema <- readLines(url)
  # We can read the schema by using github raw contents instead of adding the schema into a docker image, however, it would make an overhead. 
  
  faasr_schema <- readLines("FaaSr.schema.json")
  # Use json_validator: make faasr_schema_valid as a validator. ajv should be used as an engine.
  faasr_schema_valid <- json_validator(faasr_schema, engine="ajv")

  # if faasr_payload is valid json, do nothing.
  if (validate(faasr_payload)){NULL} else{
  # Else, return error and stop.
	  log <- attr(validate(faasr_payload),"err")
	  cat('{\"msg\":\"',log,'\"}', "\n")
	  stop()}

  # Make faasr_payload a list to parse.
  faasr <- fromJSON(faasr_payload)
	
  # schema check - if it returns TRUE, return faasr
  if (faasr_schema_valid(faasr_payload)){return(faasr)} else{
	  #if it returns FALSE, return an error 
	  cat('{\"msg\":\"invalid faasr payload\"}', "\n")
          stop()
	  
	  # Room for the different way: it can return 1. error msg, 2. logs from jsonvalidate.
	  #message_schema <- attr(faasr_schema_valid(faasr_payload, verbose=TRUE, greedy=TRUE),"errors")
	  #tag <- c("schemaPath", "message")
	  #log <- message_schema[,tag]
	  #log_json <- toJSON(log)
	  #cat('{\"msg\":\"',log_json,'\"}', "\n")
	  }
}

faasr_get_user_function_args <- function(faasr) {
  # faasr is the list parsed/validated from JSON payload
  # First extract the name of the user function to invoke
  user_function = faasr$FunctionInvoke
  
  # Now extract the arguments for this function
  args = faasr$FunctionList[[user_function]]$Arguments
  return(args)
}

faasr_put_file <- function(faasr, server_name, local_folder, local_file, remote_folder, remote_file) {
  # This should put a file into S3
  # validate server_name exists
  if (server_name %in% names(faasr$DataStores)){NULL
  # if it doesn't exist, return an error and stop
   } else{cat('{\"msg\":\"invalid logging server name\"}', "\n")
          stop()}
	
  # faasr is the list parsed/validated from JSON payload
  # The name of the S3 server is server_name, a string that references an entry in the list stored in faasr with S3 configuration
  # local and remote folder file names arer strings
  target_s3 <- faasr$DataStores[[server_name]]
  put_file <- paste0(local_folder,"/",local_file)
  put_file_s3 <- paste0(remote_folder, "/", remote_file)
  
  # prepare env variables for S3 access
  #Sys.setenv("AWS_ACCESS_KEY_ID"=target_s3$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_s3$SecretKey, "AWS_DEFAULT_REGION"=target_s3$Region, "AWS_SESSION_TOKEN" = "")
  s3<-paws::s3(
	  config=list(
		  credentials=list(
			  creds=list(
				  access_key_id=target_s3$AccessKey,
				  secret_access_key=target_s3$SecretKey)),
		  region=target_s3$Region)
	  )
  # use aws.s3 to put data into the server
  #put_object(file=put_file, object=put_file_s3, bucket=target_s3$Bucket)
  result<-s3$put_object(Body=put_file, Key=put_file_s3, Bucket=target_s3$Bucket)	
}

faasr_get_file <- function(faasr, server_name, remote_folder, remote_file, local_folder, local_file) {
  # This should get a file from S3
  # validate server_name exists
  if (server_name %in% names(faasr$DataStores)){NULL

  # if it doesn't exist, return an error and stop
   } else{cat('{\"msg\":\"invalid logging server name\"}', "\n")
          stop()}
	
  # faasr is the list parsed/validated from JSON payload
  # The name of the S3 server is server_name, a string that references an entry in the list stored in faasr with S3 configuration
  # local and remote folder file names arer strings	
  target_s3 <- faasr$DataStores[[server_name]]
  get_file <- paste0(local_folder,"/",local_file)
  get_file_s3 <- paste0(remote_folder, "/", remote_file)
  if (!dir.exists(local_folder)){dir.create(local_folder, recursive=TRUE)}
	
  # TBD prepare env variables for S3 access
  #Sys.setenv("AWS_ACCESS_KEY_ID"=target_s3$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_s3$SecretKey, "AWS_DEFAULT_REGION"=target_s3$Region, "AWS_SESSION_TOKEN" = "")
  s3<-paws::s3(
	  config=list(
		  credentials=list(
			  creds=list(
				  access_key_id=target_s3$AccessKey,
				  secret_access_key=target_s3$SecretKey)),
		  region=target_s3$Region)
	  )
  # TBD use aws.s3 to get data from the server	
  #save_object(get_file_s3, file=get_file, bucket=target_s3$Bucket)
  if (file.exists(get_file)){file.remove(get_file)}
  result<-s3$download_file(Key=get_file_s3, Filename=get_file, Bucket=target_s3$Bucket)
}

faasr_log <- function(faasr,log_message) {
  # Logs a message to the S3 log server
  # faasr is the list parsed/validated from JSON payload
  # the name of the S3 server is implicit from the validated JSON payload, key LoggingServer
  # the name of the log file should be folder "logs" and file name "faasr_log_" + InvocationID + ".txt"
  
  # extract name of logging server
  log_server_name = faasr$LoggingServer
  
  # validate server_name exists
  if (log_server_name %in% names(faasr$DataStores)){NULL
  
  # if it doesn't exist, return an error and stop
   } else{cat('{\"msg\":\"invalid logging server name\"}', "\n")
          stop()}
	
  # prepare env variables for S3 access
  log_server <- faasr$DataStores[[log_server_name]]
  #Sys.setenv("AWS_ACCESS_KEY_ID"=log_server$AccessKey, "AWS_SECRET_ACCESS_KEY"=log_server$SecretKey, "AWS_DEFAULT_REGION"=log_server$Region, "AWS_SESSION_TOKEN" = "")
  s3<-paws::s3(
	  config=list(
		  credentials=list(
			  creds=list(
				  access_key_id=log_server$AccessKey,
				  secret_access_key=log_server$SecretKey)),
		  region=log_server$Region)
	  )
  # set file name to be "faasr_log_" + faasr$InvocationID + ".txt"
  log_folder <- paste0("FaaSrLogs/", faasr$InvocationID)
  log_file <- paste0(log_folder, "/", faasr$FunctionInvoke,".txt")	
  if (!dir.exists(log_folder)){dir.create(log_folder, recursive=TRUE)}
	
  # use aws.s3 to get log file from the server
  #if (object_exists(log_file, log_server$Bucket)) {save_object(log_file, file=log_file, bucket=log_server$Bucket)}
  check_log_file <- s3$list_objects_v2(Bucket=log_server$Bucket, Prefix=log_file)
  if(length(check_log_file$Contents)!=0){
	  if (file.exists(log_file)){file.remove(log_file)}
	  s3$download_file(Bucket=log_server$Bucket, Key=log_file, Filename=log_file)}
	
  # append message to the local file
  logs <- log_message
  write.table(logs, log_file, col.names=FALSE, row.names = FALSE, append=TRUE, quote=FALSE)
	
  # use aws.s3 to put log file back into server
  #put_object(file=log_file, object=log_file, bucket=log_server$Bucket)
  s3$put_object(Body=log_file, Key=log_file, Bucket=log_server$Bucket)	
}

faasr_trigger <- function(faasr) {
  # Sends triggers to functions that the current function should invoke
  # faasr is the list parsed/validated from JSON payload
  
  # First extract the name of the user function
  user_function = faasr$FunctionInvoke

  # Now get the list of InvokeNext
  invoke_next = faasr$FunctionList[[user_function]]$InvokeNext
 
  # check if the list is empty or not
  if (length(invoke_next) == 0){cat('{\"msg\":\"success_',user_function,'\"}', "\n")} else {
    
    # TBD iterate through invoke_next and use FaaS-specific mechanisms to send trigger
    # use "for" loop to iteratively check functions in invoke_next list
    for (invoke_next_function in invoke_next){
		  
       #Change the FunctionInvoke to next function name
       faasr$FunctionInvoke <- invoke_next_function
		   
       # determine FaaS server name via faasr$FunctionList[[invoke_next_function]]$FaaSServer
       next_server <- faasr$FunctionList[[invoke_next_function]]$FaaSServer
		   
       # validate that FaaS server name exists in faasr$ComputeServers list
       if (next_server %in% names(faasr$ComputeServers)){NULL
       } else{cat('{\"msg\":\"invalid server name\"}', "\n")
               break}
       
       # check FaaSType from the named compute server
       next_server_type <- faasr$ComputeServers[[next_server]]$FaaSType
      
       # if OpenWhisk - use OpenWhisk API to send trigger
       if (next_server_type=="OpenWhisk"){ 
	 # Set the env values for the openwhisk action.
         api_key <- faasr$ComputeServers[[next_server]]$API.key
	 region <- faasr$ComputeServers[[next_server]]$Region
	 namespace <- faasr$ComputeServers[[next_server]]$Namespace
	 actionname <- faasr$FunctionList[[invoke_next_function]]$Actionname
		
	 #Openwhisk - Get a token by using the API key
	 # URL is the ibmcloud's iam center.
	 url <- "https://iam.cloud.ibm.com/identity/token"
	       
	 # Body contains authorization type and api key
	 body <- list(grant_type = "urn:ibm:params:oauth:grant-type:apikey",apikey=api_key)

	 # Header is HTTR request's header.
	 headers <- c("Content-Type"="application/x-www-form-urlencoded")

	 # Use httr::POST to send the POST request to the IBMcloud iam centers to get a token.
	 response <- POST(url = url,body = body,encode = "form",add_headers(.headers = headers))

	 # Parse the result to get a token.
	 result <- content(response, as = "parsed")

	 # if result returns no error(length is 0), define token.
	 if (length(result$errorMessage)==0){token <- paste("Bearer",result$access_token)

	 # if result returns an error, return an error message and stop.				     
	 } else {faasr_log(faasr, result$errorMessage)
		 cat('{\"msg\":\"unable to invoke next action, authentication error\"}', "\n")
			break}
	 

	 #Openwhisk - Invoke next action - action name should be described.
	 # Reference: https://cloud.ibm.com/apidocs/functions
	 # URL is a form of "https://region.functions.cloud.ibm.cloud/api/v1/namespaces/namespace/actions/actionname",
	 
	 # blocking=TRUE&result=TRUE is optional
	 url_2<- paste0("https://",region,".functions.cloud.ibm.com/api/v1/namespaces/",namespace,"/actions/",actionname,"?blocking=false&result=false")
	       
	 # header is HTTR request headers      
	 headers_2 <- c("accept"="application/json", "authorization"=token, "content-type"="application/json")
	       
	 # data is a body and it should be a JSON. To pass the payload, toJSON is required.
	 data_2<-toJSON(faasr, auto_unbox=TRUE)
	       
	 # Make one option for invoking RCurl
	 curl_opts_2 <- list(post=TRUE, httpheader=headers_2, postfields=data_2)
	       
	 # Perform RCurl::curlPerform to send the POST request to IBMcloud function server.
	 response_2 <- curlPerform(url=url_2, .opts=curl_opts_2)
	       
       # if next action's server is not Openwhisk, it returns a message about the next function.
       } else {cat('{\"msg\":\"success_',user_function,'_next_action_',invoke_next_function,'will_be_executed by_',next_server_type,'\"}', "\n")}
      
	    
       # if Lambda - use Lambda API
       if (next_server_type=="Lambda"){
	# get next function server
        target_server <- faasr$ComputeServers[[next_server]]
        
	# prepare env variables for lambda
        Sys.setenv("AWS_ACCESS_KEY_ID"=target_server$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_server$SecretKey, "AWS_DEFAULT_REGION"=target_server$Region, "AWS_SESSION_TOKEN" = "")
        
	# set invoke request body, it should be a JSON. To pass the payload, toJSON is required.
	payload_json <- toJSON(faasr, auto_unbox = TRUE)
        
	# Create a Lambda client using paws
        lambda <- paws::lambda()
	
	# Invoke next function with FunctionName and Payload, receive trigger response
        response <- lambda$invoke(
          FunctionName = faasr$FunctionInvoke,
          Payload = payload_json
        )
        
	# Check if next function be invoked successfully
        if (response$StatusCode == 200) {
          cat("Successfully invoked:", faasr$FunctionInvoke, "\n")
        } else {
          cat("Error invoking: ",faasr$FunctionInvoke," reason:", response$StatusCode, "\n")
        }
      } else {
        cat('{\"msg\":\"success_',user_function,'_next_action_',invoke_next_function,'will_be_executed by_',next_server_type,'\"}', "\n")
      }

       # if GitHub Actions - use GH Actions
       if (next_server_type=="GitHubActions"){ 
        # Set env values for GitHub Actions event
        pat <- faasr$ComputeServers[[next_server]]$Token
        username <- faasr$ComputeServers[[next_server]]$UserName
        repo <- faasr$ComputeServers[[next_server]]$RepoName
        workflow_file <- faasr$ComputeServers[[next_server]]$WorkflowName
        git_ref <- faasr$ComputeServers[[next_server]]$Ref
	
	# Set inputs for the workflow trigger event with InvocationID and Next_Invoke_Function_Name
        input_id <- faasr$InvocationID
        input_invokename <- faasr$FunctionInvoke

        # The inputs for the workflow
        inputs <- list(
          ID = input_id,
          InvokeName = input_invokename
        )

        # Set the URL for the REST API endpoint of next action
        url <- paste0("https://api.github.com/repos/", username, "/", repo, "/actions/workflows/", workflow_file, "/dispatches")

        # Set the body of the POST request with github ref and inputs
        body <- list(
          ref = git_ref,
          inputs = inputs
        )

        # Use httr::POST to send the POST request
	# Reference link for POST request: https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28
        response <- POST(
          url = url,
          body = body,
          encode = "json",
          add_headers(
            Authorization = paste("token", pat),
            Accept = "application/vnd.github.v3+json",
            "X-GitHub-Api-Version" = "2022-11-28"
          )
        )
        
	# Check if next action be invoked successfully 
        if (status_code(response) == 204) {
          cat("GitHub Action: Successfully invoked:", faasr$FunctionInvoke, "\n")
        } else {
          cat("GitHub Action: error happens when invoke next function\n")
        }
      } else { 
        cat('{\"msg\":\"success_',user_function,'_next_action_',invoke_next_function,'will_be_executed by_',next_server_type,'\"}', "\n")
      }

    }
   }
}
	
#lock implementation - acquire
faasr_acquire<-function(faasr){
	# Call faasr_rsm to get a lock, faasr_rsm returns either TRUE or FALSE
	Lock<-faasr_rsm(faasr)
	
	#if function acquires a lock, it gets out of the loop
	while(TRUE){
		# if Lock is TRUE i.e., this function has a lock, return TRUE i.e., get out of the While loop
		if (Lock){return(TRUE)}else
		{
			
		#if it doesn't, keep trying to get the flag&lock by calling faasr_rsm again until it returns TRUE.
		Lock<-faasr_rsm(faasr)
		}
	}
}


# lock implementation - release
faasr_release<-function(faasr){
	# Set env for locks.
	lock_name <- paste0("FaaSrLogs/", faasr$InvocationID,"/",faasr$FunctionInvoke,"./lock")
	target_s3 <- faasr$LoggingServer
	target_s3 <- faasr$DataStores[[target_s3]]
	#Sys.setenv("AWS_ACCESS_KEY_ID"=target_s3$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_s3$SecretKey, "AWS_DEFAULT_REGION"=target_s3$Region, "AWS_SESSION_TOKEN" = "")
	s3<-paws::s3(
	config=list(
		credentials=list(
			creds=list(
				access_key_id=target_s3$AccessKey,
				secret_access_key=target_s3$SecretKey)),
		region=target_s3$Region)
	)
	# delete the file named ".lock"
	#delete_object(lock_name, target_s3$Bucket)
	s3$delete_object(Key=lock_name, Bucket=target_s3$Bucket)
}



# "waiting" implementation
faasr_check<-function(faasr, pre){
	#if predecessors are more 2, it gets through codes below, if not (0 or 1 predecessor), just pass this
	if (length(pre)==0){
		if (length(faasr$InvocationID)==0){faasr$InvocationID<-UUIDgenerate()
  		# if InvocationID doesn't have valid form, generate a UUID 
  		} else if (UUIDvalidate(faasr$InvocationID)==FALSE){faasr$InvocationID<-UUIDgenerate()}

		target_s3 <- faasr$LoggingServer
		target_s3 <- faasr$DataStores[[target_s3]]
		Sys.setenv("AWS_ACCESS_KEY_ID"=target_s3$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_s3$SecretKey, "AWS_DEFAULT_REGION"=target_s3$Region, "AWS_SESSION_TOKEN" = "")
		s3<-paws::s3(
	  		config=list(
		  		credentials=list(
			  		creds=list(
				  		access_key_id=target_s3$AccessKey,
				  		secret_access_key=target_s3$SecretKey)),
		  		region=target_s3$Region)
	  	)
		
		idfolder <- paste0("FaaSrLogs/",faasr$InvocationID, "/")

		check_UUIDfolder<-s3$list_objects_v2(Prefix=idfolder, Bucket=target_s3$Bucket)
		#if (object_exists(idfolder, target_s3$Bucket)){
		#	cat('{\"msg\":\"InvocationID already exists\"}', "\n")
		#	stop()
		#} else { put_folder(faasr$InvocationID, bucket=target_s3$Bucket) }
		if (length(check_UUIDfolder$Contents)!=0){
			cat('{\"msg\":\"InvocationID already exists\"}', "\n")
			stop()
		}else{s3$put_object(Key=idfolder, Bucket=target_s3$Bucket)}	
		
		
	if (length(pre)>1){

		# Set env for checking
		log_server_name = faasr$LoggingServer
		log_server <- faasr$DataStores[[log_server_name]]
		#Sys.setenv("AWS_ACCESS_KEY_ID"=log_server$AccessKey, "AWS_SECRET_ACCESS_KEY"=log_server$SecretKey, "AWS_DEFAULT_REGION"=log_server$Region, "AWS_SESSION_TOKEN" = "")
		s3<-paws::s3(
	  		config=list(
		  		credentials=list(
			  		creds=list(
				  		access_key_id=log_server$AccessKey,
				  		secret_access_key=log_server$SecretKey)),
		  		region=log_server$Region)
	  	)
		
		idfolder <- paste0("FaaSrLogs/",faasr$InvocationID, "/")
		
		#check all "predecessorname.done" exists. If TRUE, it passes, elif FALSE, it stops
		for (func in pre){
			
			# check filename is "functionname.done"
			file_names <- paste0(idfolder,"/",func,".done") 
			check_fn_done<-s3$list_objects_v2(Bucket=log_server$Bucket, Prefix=file_names)
			# if object exists, do nothing.
			#if (object_exists(file_names, log_server$Bucket)){
			#	NULL
			#} else{
			#	faasr_log(faasr, "error:function should wait")
			#	stop()
			#}
			# if object doesn't exist, leave a log that this function should wait and will be discarded				  
			if (length(check_fn_done$Contents)==0){
				faasr_log(faasr, "error:function should wait")
				stop()
			}
		}
		
		# put random number into the file named "function.candidate"
		random_number <- sample(1:10000, 1)
		id_folder <- paste0("FaaSrLog/", faasr$InvocationID)
		# Check whether directory exists, if not, create one.
		if (!dir.exists(id_folder)){dir.create(id_folder, recursive=TRUE)}
		file_names <- paste0(id_folder,"/",faasr$FunctionInvoke,".candidate")

		# Below is to avoid the race condition
		# acquire a Lock
		faasr_acquire(faasr)
		
		# if file named "function.candidate" exists, save it to the local
		#if (object_exists(file_names, log_server$Bucket)){
		#	save_object(file_names, file=file_names, bucket=log_server$Bucket)
		#}
		check_fn_candidate<-s3$list_objects_v2(Bucket=log_server$Bucket, Prefix=file_names)
		if (length(check_fn_candidate)!=0){
			if (file.exists(file_names)){file.remove(file_names)}
			s3$download_file(Key=file_names, Filename=file_names, Bucket=log_server$Bucket)
		}
		
		# append random number to the file / put it back to the s3 bucket 
		write.table(random_number, file_names, col.names=FALSE, row.names = FALSE, append=TRUE, quote=FALSE)
		
		#put_object(file=file_names, object=file_names, bucket=log_server$Bucket)
		result<-s3$put_object(Body=file_names, Key=file_names, Bucket=log_server$Bucket)

		
		# save it to the local, again
		#save_object(file_names, file=file_names, bucket=log_server$Bucket)
		if (file.exists(file_names)){file.remove(file_names)}
		s3$download_file(Key=file_names, Filename=file_names, Bucket=log_server$Bucket)
		
		# release the Lock
		faasr_release(faasr)
		
		# if the first line of the file matches the random number, it will process codes behind it, else, it stops.
		if (as.character(random_number) == readLines(file_names,1)){
			NULL
			}else{
			cat('{\"msg\":\"Number does not match\"}', "\n")
			stop()
			}

		}
	}
}


# Read-Set Memory implementation
faasr_rsm <- function(faasr){
	# Set env for flag and lock
	flag_content <- as.character(sample(1:1000,1))
	flag_path <- paste0("FaaSrLogs/", faasr$InvocationID,"/",faasr$FunctionInvoke,"/flag/")
	flag_name <- paste0(flag_path,flag_content)
	lock_name <- paste0("FaaSrLogs/", faasr$InvocationID,"/",faasr$FunctionInvoke,"./lock")

	# Set env for the storage.
	target_s3 <- faasr$LoggingServer
	target_s3 <- faasr$DataStores[[target_s3]]
	#Sys.setenv("AWS_ACCESS_KEY_ID"=target_s3$AccessKey, "AWS_SECRET_ACCESS_KEY"=target_s3$SecretKey, "AWS_DEFAULT_REGION"=target_s3$Region, "AWS_SESSION_TOKEN" = "")
 	s3<-paws::s3(
	  		config=list(
		  		credentials=list(
			  		creds=list(
				  		access_key_id=target_s3$AccessKey,
				  		secret_access_key=target_s3$SecretKey)),
		  		region=target_s3$Region)
	  	)
	
	# Make a loop
	while(TRUE){
		# Put a object named "functionname/flag" with the content "T" into the S3 bucket
		#put_object("T", flag_name, target_s3$Bucket)
		result<-s3$put_object(Key=flag_name, Bucket=target_s3$Bucket)
		
		# if someone has a flag i.e.,faasr_anyone_else_interested returns TRUE, delete_flag and try again.
		if(faasr_anyone_else_interested(faasr, target_s3, flag_path, flag_name)){
			#delete_object(flag_name, target_s3$Bucket)
			s3$delete_object(Key=flag_name, Bucket=target_s3$Bucket)

		# if nobody has a flag i.e.,faasr_anyone_else_interested returns FALSE, check the lock condition.
		}else{ 
			
			# if ".lock" exists in the bucket, return FALSE, and try all over again.
			check_lock <- s3$list_objects_v2(Prefix=lock_name, Bucket=target_s3$Bucket)
			if (length(check_lock$Contents)!=0){
				return(FALSE)
			#if (object_exists(lock_name, target_s3$Bucket)){
			#	return(FALSE)

			# if ".lock" does not exist, make a new lock with the content of flag_content
			}else{
				#put_object(flag_content, lock_name, target_s3$Bucket)
				writeLines(flag_content, "lock.txt")
				result <- s3$put_object(Body="lock.txt", Key=lock_name, Bucket=target_s3$Bucket)
				file.remove("lock.txt")
				
				# release the flag and get out of the while loop
				#delete_object(flag_name, target_s3$Bucket)
				s3$delete_object(Key=flag_name, Bucket=target_s3$Bucket)
				return(TRUE)	
			}
		}
		
	}
}




# Anyone_else_interested implementation
faasr_anyone_else_interested <- function(faasr, target_s3, flag_path, flag_name){
        # get_bucket_df function may have Compatibility problem for some region (us-east-2, ca-central-1.., working in these regions may have error ) 
	# which the bucket object "Owner" part does not have "DisplayName", just have "ID" value.
	# alternative package: may use "paws" library list_objects_v2 function
	# pool is a list of flag names
	#pool <- get_bucket_df(target_s3$Bucket,prefix=flag_path)
	check_pool <- s3$list_objects_v2(Bucket=target_s3$Bucket, Prefix=flag_path)
	pool <- lapply(check_pool$Contents, function(x) x$Key)
	
	# if this function sets the flag and it is the only flag, return FALSE, if not, return TRUE
	if (flag_name %in% pool$Key && length(pool$Key)==1){
		return(FALSE)
	}else{
		return(TRUE) 
	}
}




# workflow implementation - check loop iteratively, predecessors.
# TBD check unreachable
faasr_check_workflow_cycle <- function(faasr){
	
	# build empty lists for the graph and predecessors.
	graph <- list()
	
	# build the graph indicating adjacent nodes, e.g., "F1":["F2","F3"], so on.
	for (func in names(faasr$FunctionList)){
		graph[[func]] <- faasr$FunctionList[[func]]$InvokeNext
	}
	
	# build an empty list of stacks - this will prevent the infinite loop
	stack <- list()
	# implement dfs - recursive function
	dfs <- function(start, target){
		
		# find target in the graph's successor. If it matches, there's a loop
		if (target %in% graph[[start]]){
			cat('{\"msg\":\"function loop found\"}', "\n")
			stop()
		}
		
		# add start, marking as "visited"
		stack <<- c(stack, start)
		
		# set one of the successors as another "start"
		for (func in graph[[start]]){
			
			# if new "start" has been visited, do nothing
			if (func %in% stack){
				NULL

			# if not, keep checking the DAG.
			} else {
				dfs(func, target)
			}
		}
	}
	
	# do dfs starting with function invoke.
	dfs(faasr$FunctionInvoke, faasr$FunctionInvoke)
	return(graph)
}

faasr_predecessors_list<- function(faasr, graph){
	# find the predecessors and add them to the list "pre" 
	pre <- list()
	for (func in names(faasr$FunctionList)){
		if (faasr$FunctionInvoke %in% graph[[func]]){
		pre <- c(pre, func)
		} 
	}

	return(pre) 
}



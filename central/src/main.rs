use clap::Parser;
use warp::{Filter, Reply};
use serde::{Serialize,Deserialize};
use std::{sync::Arc, collections::HashMap};
use tokio::sync::Mutex;

/// App Configuration
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Args {
    // The address the central uses to listen to server requests
    #[clap(default_value = "0.0.0.0", long, env)]
    hostname: String,

    // The port the central uses to listen to server requests
    #[clap(default_value = "8086", long, env)]
    port: u16,

    // The interval (in seconds) between central pings to models
    #[clap(default_value = "60", long, env)]
    ping_interval: u64,

    // The maximum number of failed pings before a model is dropped
    #[clap(default_value = "3", long, env)]
    max_failed_pings: u32,
    
    // By default is None, if set pings a server on launch and if alive registers it
    #[clap(default_value = None, long, env)]
    initial_ping: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ModelRecord {
    pub name: String,
    pub address: String,
    pub owner: String,
    pub is_quantized: bool,
}

#[derive(Deserialize, Clone, Debug)]
struct ModelInfo {
    docker_label: Option<String>,
    max_batch_total_tokens: u32,
    max_best_of: u32,
    max_concurrent_requests: u32,
    max_input_length: u32,
    max_stop_sequences: u32,
    max_total_tokens: u32,
    max_waiting_tokens: u32,
    model_device_type: String,
    model_dtype: String,
    model_id: String,
    model_pipeline_tag: String,
    model_sha: String,
    sha: String,
    validation_workers: u32,
    version: String,
    waiting_served_ratio: f32,
}

type Models = Arc<Mutex<HashMap<String, ModelRecord>>>;


// define function to print model info
fn print_model_record(record: &ModelRecord) {
    if record.is_quantized {
        println!("\t{} (quant) - {} by {}", record.name, record.address, record.owner);
    } else {
        println!("\t{} - {} by {}", record.name, record.address, record.owner);
    }
}

#[tokio::main]

async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let hostname = args.hostname;
    let port = args.port;
    let ping_interval = args.ping_interval;
    let initial_ping = args.initial_ping;
    // get current user from env
    let user = whoami::username();

    let models: Models = Arc::new(Mutex::new(HashMap::new()));

    fn with_models(models: Models) -> impl Filter<Extract = (Models,), Error = std::convert::Infallible> + Clone {
        warp::any().map(move || models.clone())
    }
    
    async fn handle_model_notice(encoded_id: String, record: ModelRecord, models: Models) -> Result<impl warp::Reply, warp::Rejection> {
        println!("Received model notice for {}", encoded_id);
        let model_id = urlencoding::decode(&encoded_id).unwrap();
        models.lock().await.insert(model_id, record);
        Ok(warp::reply::with_status(
            "Model registered successfully",
            warp::http::StatusCode::OK,
        ))
    }

    async fn handle_list_models(models: Models) -> Result<impl warp::Reply, warp::Rejection> {
        let models = models.lock().await;
        // print for debug
        let mut models_list: Vec<ModelRecord> = vec![];
        for (_, record) in models.iter() {
            models_list.push(record.clone());
        }
        Ok(warp::reply::with_status(
            warp::reply::json(&models_list).into_response(),
            warp::http::StatusCode::OK,
        ))
    }

    let model_notice_route = warp::path("model_up")
        .and(warp::path::param::<String>())
        .and(warp::post())
        .and(warp::body::json())
        .and(with_models(models.clone()))
        .and_then(handle_model_notice);

    let list_models_route = warp::path("list_models")
        .and(warp::get())
        .and(with_models(models.clone()))
        .and_then(handle_list_models);

    let catch_all = warp::any()
        .map(||{
            println!("Warning: Received a request on an unhandled route");
            warp::reply::with_status(
                "Unhandled route!",
                warp::http::StatusCode::NOT_FOUND,
            )
    });

    let routes = model_notice_route
        .or(list_models_route)
        .or(catch_all);

    let listener = warp::serve(routes).run((hostname.parse::<std::net::IpAddr>().unwrap(), port));
    let monitor = async {
        // ping server if provided
        if let Some(model_addr) = initial_ping {
            // split server into ip and port variables strings
            let model_ip = model_addr.split(":").collect::<Vec<&str>>()[0];
            let model_port = model_addr.split(":").collect::<Vec<&str>>()[1];
            
            let url = format!("http://{}:{}/info", model_ip, model_port);
            let response = reqwest::get(&url).await;
            match response {
                Ok(response) => {
                    if response.status().is_success() {
                        let body = response.text().await?;
                        let info: ModelInfo = serde_json::from_str(&body)?;
                        let address = format!("{}:{}", model_ip, model_port);
                        models.lock().await.insert(
                            info.model_id.clone(), 
                            // TODO: this is not the correct values
                            // we should get these from the model
                            ModelRecord {
                                name: info.model_id.clone(),
                                address: address,
                                owner: user.to_string(),
                                is_quantized: false,
                            });
                    } else {
                        println!("Model not alive");
                    }
                },
                Err(e) => {
                    println!("Model not alive");
                }
            };
        }

        // every Ns, for every model, ping in /health, and if not alive remove from models ()
        loop {
            let mut models = models.lock().await;
            let mut keys_removal: Vec<String> = vec![];
            
            for (model, record) in models.iter() {
                let url = format!("http://{}/health", record.address);
                let response = reqwest::get(&url).await;
                match response {
                    Ok(response) => {
                        if !response.status().is_success() {
                            keys_removal.push(model.to_string());
                        }
                    },
                    Err(e) => {
                        keys_removal.push(model.to_string());
                    }
                }
            };

            let mut dropped_models: HashMap<String, ModelRecord> = HashMap::new();
            for key in keys_removal {
                if let Some(record) = models.remove(&key) {
                dropped_models.insert(key, record);
                }
            }

            // print current time
            println!("------------------");
            println!("Current time: {}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
            // print models that stayed, one in each line
            println!("Current Models:");
            for (model, record) in models.iter() {
                print_model_record(record);
            }
            // print dropped models
            println!("Dropped Models:");
            for (model, record) in dropped_models.iter() {
                print_model_record(record);
            }

            std::mem::drop(models);
            tokio::time::sleep(std::time::Duration::from_secs(ping_interval)).await;
        }

        Ok(()) as Result<(), Box<dyn std::error::Error>>
    };

    // wrap listener to go into try join
    let listener = async {
        listener.await;
        Ok(())
    };
    tokio::try_join!(listener, monitor);
    Ok(())
}

